SELECT 
    i.id,
    p.pname AS project,
    p.pkey AS project_code,
    i.issuenum AS numero,
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
LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
        'create_date', a.created, 
        'update_date', a.updated, 
        'auteur', u3.lower_user_name, 
        'description', a.actionbody
    )) AS commentaires
    FROM jiraaction a
    LEFT JOIN app_user u3 ON a.author = u3.user_key
    WHERE a.issueid = i.id
) c ON true
LEFT JOIN LATERAL (
    SELECT jsonb_agg(l.label) AS etiquettes
    FROM label l
    WHERE l.issue = i.id
) e ON true
LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
        'field', cv.cfname, 
        'option', co.customvalue, 
        'value', COALESCE(
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
-- Parent d'une sous-tache. En Jira DC la relation n'est pas une colonne de
-- jiraissue (contrairement au Cloud) : elle vit dans issuelink, avec un
-- issuelinktype de style 'jira_subtask' (source = parent, destination = enfant).
-- Colonnes scalaires plutot qu'une table enfant : c'est le cas d'usage courant,
-- autant qu'il soit exploitable sans jointure cote BigQuery.
LEFT JOIN LATERAL (
    SELECT
        ip.id AS parent_id,
        pp.pkey || '-' || ip.issuenum AS parent_key,
        ip.summary AS parent_resume
    FROM issuelink il
    JOIN issuelinktype lt ON lt.id = il.linktype
    JOIN jiraissue ip ON ip.id = il.source
    JOIN project pp ON pp.id = ip.project
    WHERE il.destination = i.id
      AND lt.pstyle = 'jira_subtask'
    LIMIT 1
) par ON true
-- Tous les liens de l'issue, dans les deux sens : sous-taches (style
-- 'jira_subtask') et liens classiques (clone, bloque, est lie a...).
-- Perf : le OR sur source/destination suppose que la replique DMZ porte les index
-- de issuelink sur ces deux colonnes. Sans eux, ce LATERAL degenere en seq scan
-- par ligne — a surveiller sur IMP (42 698 issues).
LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
        'type', lt.linkname,
        'style', lt.pstyle,
        'sens', CASE WHEN il.source = i.id THEN 'sortant' ELSE 'entrant' END,
        'libelle', CASE WHEN il.source = i.id THEN lt.outward ELSE lt.inward END,
        'issue_key', p2.pkey || '-' || i2.issuenum,
        'resume', i2.summary
    )) AS liens
    FROM issuelink il
    JOIN issuelinktype lt ON lt.id = il.linktype
    JOIN jiraissue i2 ON i2.id = CASE WHEN il.source = i.id THEN il.destination ELSE il.source END
    JOIN project p2 ON p2.id = i2.project
    WHERE il.source = i.id OR il.destination = i.id
) lk ON true
-- Metadonnees des pieces jointes uniquement : le binaire vit sur le filesystem
-- Jira, hors base.
LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
        'nom', fa.filename,
        'mimetype', fa.mimetype,
        'taille_octets', fa.filesize,
        'auteur', u5.lower_user_name,
        'create_date', fa.created
    )) AS pieces_jointes
    FROM fileattachment fa
    LEFT JOIN app_user u5 ON fa.author = u5.user_key
    WHERE fa.issueid = i.id
) att ON true
WHERE
    p.pkey = %s;