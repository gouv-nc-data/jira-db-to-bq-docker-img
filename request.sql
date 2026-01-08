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
    e.etiquettes,
    c.commentaires,
    fields.custom_fields,
    cl.changelog
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
    issuesecurityscheme sl ON sl.id = i.security
LEFT JOIN 
    app_user u_creator ON i.creator = u_creator.user_key
LEFT JOIN 
    app_user u1 ON i.reporter = u1.user_key
LEFT JOIN 
    app_user u2 ON i.assignee = u2.user_key

-- Sous-requêtes pour les données JSON (Commentaires, Etiquettes, Champs persos, Historique)
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
WHERE 
    p.pkey = %s;