-- Les issues du projet, calculées une seule fois.
-- Les CTE d'agrégation ci-dessous s'appuient dessus au lieu d'être corrélées à
-- chaque ligne de jiraissue : c'est ce qui évite de rebalayer issuelink et
-- fileattachment une fois par issue (voir le commentaire de liens_plats).
--
-- `cle` (PSPC-447) est calculée ici pour être disponible partout : sur l'issue
-- elle-même et dans chaque agrégat enfant, sans rejoindre project à chaque fois.
WITH issues_projet AS (
    SELECT i.id,
           p.pkey || '-' || i.issuenum AS cle
    FROM jiraissue i
    JOIN project p ON p.id = i.project
    WHERE p.pkey = %s
),
-- Les liens de l'issue vont dans les deux sens, ce qui s'écrivait naturellement
-- `WHERE il.source = i.id OR il.destination = i.id`. Mais un OR sur deux colonnes
-- est ininstrumentable par un index, et la réplique DMZ ne porte de toute façon
-- que pk_issuelink : chaque issue déclenchait donc un Seq Scan complet des
-- 426 668 lignes d'issuelink (EXPLAIN sur EP : coût 313 M, run tué par
-- activeDeadlineSeconds). On déplie ici les deux sens en une seule passe, ce qui
-- supprime le OR et rend l'agrégation groupable.
--
-- La branche 'entrant' exclut les auto-liens (source = destination, 1 occurrence
-- en base) : ils sortent déjà par la branche 'sortant', comme le faisait le
-- CASE de la version corrélée. Sans ce filtre ils seraient comptés deux fois.
liens_plats AS (
    SELECT il.source AS issue_id, ip.cle AS issue_cle,
           il.destination AS autre_id,
           il.linktype, il.sequence, il.id, 'sortant' AS sens
    FROM issuelink il
    JOIN issues_projet ip ON ip.id = il.source
    UNION ALL
    SELECT il.destination, ip.cle,
           il.source,
           il.linktype, il.sequence, il.id, 'entrant'
    FROM issuelink il
    JOIN issues_projet ip ON ip.id = il.destination
    WHERE il.source <> il.destination
),
-- Tous les liens de l'issue : sous-tâches (style 'jira_subtask') et liens
-- classiques (clone, bloque, est lié à...).
-- issuelink.sequence porte l'ordre d'affichage défini dans Jira (l'ordre des
-- sous-tâches d'un parent) : on le remonte et on trie dessus, sans quoi
-- jsonb_agg produit un ordre non déterministe d'un run à l'autre.
liens_agg AS (
    SELECT lp.issue_id,
           jsonb_agg(jsonb_build_object(
               'issue_id', lp.issue_id,
               'issue_cle', lp.issue_cle,
               'type', lt.linkname,
               'style', lt.pstyle,
               'sens', lp.sens,
               'libelle', CASE WHEN lp.sens = 'sortant' THEN lt.outward ELSE lt.inward END,
               'issue_key', p2.pkey || '-' || i2.issuenum,
               'resume', i2.summary,
               'ordre', lp.sequence
           ) ORDER BY lp.sequence NULLS LAST, lp.id) AS liens
    FROM liens_plats lp
    JOIN issuelinktype lt ON lt.id = lp.linktype
    JOIN jiraissue i2 ON i2.id = lp.autre_id
    JOIN project p2 ON p2.id = i2.project
    GROUP BY lp.issue_id
),
-- Parent d'une sous-tâche. En Jira DC la relation n'est pas une colonne de
-- jiraissue (contrairement au Cloud) : elle vit dans issuelink, avec un
-- issuelinktype de style 'jira_subtask' (source = parent, destination = enfant).
-- Vu depuis l'enfant le lien est donc 'entrant', et autre_id porte le parent.
-- Colonnes scalaires plutôt qu'une table enfant : c'est le cas d'usage courant,
-- autant qu'il soit exploitable sans jointure côté BigQuery.
-- DISTINCT ON + ORDER BY lp.id reproduit le `ORDER BY il.id LIMIT 1` d'origine.
parents AS (
    SELECT DISTINCT ON (lp.issue_id)
           lp.issue_id,
           ipa.id AS parent_id,
           ppa.pkey || '-' || ipa.issuenum AS parent_key,
           ipa.summary AS parent_resume
    FROM liens_plats lp
    JOIN issuelinktype lt ON lt.id = lp.linktype
    JOIN jiraissue ipa ON ipa.id = lp.autre_id
    JOIN project ppa ON ppa.id = ipa.project
    WHERE lp.sens = 'entrant'
      AND lt.pstyle = 'jira_subtask'
    ORDER BY lp.issue_id, lp.id
),
-- Métadonnées des pièces jointes uniquement : le binaire vit sur le filesystem
-- Jira, hors base.
-- Même motif que liens_plats : fileattachment (1 520 807 lignes) n'a pas d'index
-- sur issueid en DMZ, donc la version corrélée la rebalayait à chaque issue.
attachments AS (
    SELECT fa.issueid,
           jsonb_agg(jsonb_build_object(
               'issue_id', fa.issueid,
               'issue_cle', ip.cle,
               'nom', fa.filename,
               'mimetype', fa.mimetype,
               'taille_octets', fa.filesize,
               'auteur', u5.lower_user_name,
               'create_date', fa.created
           ) ORDER BY fa.created, fa.id) AS pieces_jointes
    FROM fileattachment fa
    JOIN issues_projet ip ON ip.id = fa.issueid
    LEFT JOIN app_user u5 ON fa.author = u5.user_key
    GROUP BY fa.issueid
)
SELECT
    i.id,
    p.pname AS project,
    p.pkey AS project_code,
    i.issuenum AS numero,
    -- Clé Jira telle qu'affichée dans l'interface (PSPC-447). Reconstruite ici
    -- plutôt que laissée à la charge de l'utilisateur : `project_code` et
    -- `numero` seuls obligeaient chacun à refaire la concaténation, avec un
    -- cast sur numero (NUMERIC côté BigQuery) que beaucoup rataient.
    ipr.cle,
    pr.pname AS type_urgence,
    it.pname AS type_tache,
    it.pstyle AS sous_type_tache,
    i.summary AS resume,
    iss.pname AS status_tache,
    -- La table `statuscategory` (libellés) n'est pas répliquée en DMZ : seul l'id
    -- l'est, via issuestatus.statuscategory. Les 3 valeurs présentes (2, 3, 4) sont
    -- les ids standard Jira, stables entre instances.
    CASE iss.statuscategory
        WHEN 2 THEN 'A faire'
        WHEN 3 THEN 'Termine'
        WHEN 4 THEN 'En cours'
    END AS categorie_statut,
        u_creator.lower_user_name AS createur,
    u1.lower_user_name AS rapporteur,
    u2.lower_user_name AS responsable,
        res.pname AS resolution,
    sl.name AS niveau_securite,
    COALESCE(i.votes, 0) AS nb_votes,
    COALESCE(i.watches, 0) AS nb_observateurs,
    i.description,
    i.priority AS priorite,
    i.created AS create_date,
    i.updated AS update_date,
    i.resolutiondate AS resolution_date,
    i.duedate AS echeance_date,
    par.parent_id,
    par.parent_key,
    par.parent_resume,
    e.etiquettes,
    c.commentaires,
    fields.custom_fields,
    cl.changelog,
    lk.liens,
    att.pieces_jointes
FROM
    jiraissue i
-- Le périmètre vient de issues_projet : le filtre projet n'est appliqué qu'une
-- fois, dans la CTE. La requête ne porte donc qu'un seul placeholder, celui
-- que main.py passe à cursor.execute. Ne pas introduire de caractère pour-cent
-- dans ces commentaires : psycopg2 interpole la chaîne entière avant
-- PostgreSQL, et un marqueur de format en commentaire, même inerte pour le
-- moteur SQL, ferait échouer l'exécution côté Python.
JOIN
    issues_projet ipr ON ipr.id = i.id
JOIN
    project p ON p.id = i.project
LEFT JOIN
    issuetype it ON it.id = i.issuetype
LEFT JOIN
    issuestatus iss ON iss.id = i.issuestatus
LEFT JOIN
    priority pr ON pr.id = i.priority
LEFT JOIN
    resolution res ON res.id = i.resolution
LEFT JOIN
    schemeissuesecuritylevels sl ON sl.id = i.security
LEFT JOIN
    app_user u_creator ON i.creator = u_creator.user_key
LEFT JOIN
    app_user u1 ON i.reporter = u1.user_key
LEFT JOIN
    app_user u2 ON i.assignee = u2.user_key
-- Chaque agrégat enfant porte `issue_id` et `issue_cle`. dlt éclate ces tableaux
-- en tables séparées (issues__commentaires, issues__custom_fields...) dont la
-- seule clé était jusqu'ici `_dlt_parent_id` -> `issues._dlt_id` : un identifiant
-- technique, régénéré à chaque run puisque la ressource tourne en `replace` et
-- que dlt ne produit un `_dlt_id` déterministe qu'en merge upsert/insert-only
-- (voir get_root_row_id_type). Les utilisateurs ne trouvaient donc aucune clé
-- pour rattacher un commentaire ou un champ personnalisé à son issue, et toute
-- table dérivée bâtie sur `_dlt_id` cassait au run suivant. Les deux colonnes
-- ci-dessous sont des clés métier stables : coût nul, la donnée est déjà là.
--
-- Les LATERAL ci-dessous restent corrélés : jiraaction, label, customfieldvalue
-- et changegroup portent tous un index sur la colonne d'issue en DMZ
-- (action_issue, label_issue, cfvalue_issue, chggroup_issue_id), donc chaque
-- itération est un Index Scan et non un Seq Scan.
LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
        'issue_id', i.id,
        'issue_cle', ipr.cle,
        'create_date', a.created,
        'update_date', a.updated,
        'auteur', u3.lower_user_name,
        'description', a.actionbody
    )) AS commentaires
    FROM jiraaction a
    LEFT JOIN app_user u3 ON a.author = u3.user_key
    WHERE a.issueid = i.id
) c ON true
-- Les étiquettes passent d'un tableau de chaînes à un tableau d'objets pour
-- pouvoir porter la clé, comme les autres enfants. La colonne `value` de
-- issues__etiquettes est conservée sous le même nom : le changement est
-- ascendant pour les requêtes existantes.
LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
        'issue_id', i.id,
        'issue_cle', ipr.cle,
        'value', l.label
    )) AS etiquettes
    FROM label l
    WHERE l.issue = i.id
) e ON true
-- `valeur` résout le piège de la colonne `value` : pour un champ à liste de
-- choix, customfieldvalue.stringvalue porte l'id interne de l'option (38885) et
-- non son libellé (Nouméa), ce dernier vivant dans customfieldoption.customvalue.
-- Lire `value` donnait donc des identifiants incompréhensibles sur la majorité
-- des champs. `valeur` applique le COALESCE une fois pour toutes, côté source.
-- `value` et `option` sont conservées : elles restent utiles pour retrouver
-- l'option d'origine, et les retirer casserait les requêtes existantes.
--
-- `field_id` lève l'ambiguïté des champs homonymes : sur PSPC, deux jeux
-- d'options distincts (37507 et 42735-42739) remontent tous deux sous le nom
-- « Année ». Sans l'id du champ, rien ne permet de les distinguer.
LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
        'issue_id', i.id,
        'issue_cle', ipr.cle,
        'field_id', cv.id,
        'field', cv.cfname,
        'option', co.customvalue,
        'value', COALESCE(
            cfv.stringvalue,
            cfv.numbervalue::text,
            cfv.textvalue,
            cfv.datevalue::text
        ),
        'valeur', COALESCE(
            co.customvalue,
            cfv.stringvalue,
            cfv.numbervalue::text,
            cfv.textvalue,
            cfv.datevalue::text
        )
    )) AS custom_fields
    FROM customfieldvalue cfv
    JOIN customfield cv ON cfv.customfield = cv.id
    LEFT JOIN customfieldoption co ON cfv.stringvalue = co.id::text
    WHERE cfv.issue = i.id
) fields ON true
LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
        'issue_id', i.id,
        'issue_cle', ipr.cle,
        'date', cg.created,
        'auteur', u4.lower_user_name,
        'field', ci.field,
        'oldvalue', ci.oldvalue,
        'oldstring', ci.oldstring,
        'newvalue', ci.newvalue,
        'newstring', ci.newstring
    )) AS changelog
    FROM changegroup cg
    JOIN changeitem ci ON ci.groupid = cg.id
    LEFT JOIN app_user u4 ON cg.author = u4.user_key
    WHERE cg.issueid = i.id
) cl ON true
LEFT JOIN parents par ON par.issue_id = i.id
LEFT JOIN liens_agg lk ON lk.issue_id = i.id
LEFT JOIN attachments att ON att.issueid = i.id;
