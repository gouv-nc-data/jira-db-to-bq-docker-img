import os
import re
import sys
import unicodedata
from urllib import response

import dlt
from dlt.extract import make_nested_hints
from dlt.sources.sql_database import sql_database
import logging
# from loguru import logger
import google.cloud.logging

from dotenv import load_dotenv
from google.cloud import secretmanager

load_dotenv()


# Configuration Cloud Logging avec StructuredLogHandler
# Cela configure le module logging standard pour écrire des logs JSON sur stdout
# qui seront automatiquement parsés par l'agent GCP (Fluentd/Fluent Bit)
from google.cloud.logging.handlers import StructuredLogHandler

handler = StructuredLogHandler()
logging.getLogger().addHandler(handler)

# Configuration du niveau de log via variable d'environnement (défaut: INFO)
log_level_name = os.getenv("LOG_LEVEL", "INFO").upper()
log_level = getattr(logging, log_level_name, logging.INFO)
logging.getLogger().setLevel(log_level)

# Capturer les warnings Python (ex: UserWarning de BigQuery) pour qu'ils passent par le logging system
# et soient loggés en JSON avec la sévérité WARNING au lieu de sortir sur stderr (ERROR)
logging.captureWarnings(True)

# Configuration dynamique de dlt via variables d'environnement (méthode recommandée par dlt)
# On le fait en Python pour que ça suive la variable LOG_LEVEL de l'utilisateur
os.environ["RUNTIME__LOG_LEVEL"] = log_level_name
os.environ["RUNTIME__LOG_FORMAT"] = "JSON"
os.environ["LOG_FORMAT"] = "JSON" # Fallback

# On nettoie quand même les handlers existants au cas où dlt se serait déjà initialisé
dlt_logger = logging.getLogger("dlt")
dlt_logger.setLevel(log_level)
dlt_logger.handlers = []  # Supprime les handlers par défaut de dlt (évite les doublons ou le format texte)
dlt_logger.propagate = True # Remonte les logs au root logger (qui a le StructuredLogHandler)



# ---------------------------------------------------------------------------
# Vue v_issues
#
# Les tables produites par dlt sont normalisées : une table par tableau imbriqué
# (issues__custom_fields, issues__commentaires, issues__changelog...). C'est
# fidèle à la source mais peu exploitable pour un utilisateur métier, qui veut
# une ligne par issue avec ses champs personnalisés en colonnes.
#
# La vue est construite ici, après le chargement, plutôt que déclarée en
# Terraform : la liste des champs personnalisés varie d'un projet Jira à l'autre
# (72 sur PSPC, 194 sur DAVSAF) et change quand la direction ajoute un champ.
# La générer depuis les données qui viennent d'être chargées évite toute dérive
# entre le schéma réel et la vue.
#
# Forme retenue :
#   - champs personnalisés  -> colonnes (paires clé/valeur : ça se pivote)
#   - commentaires, journal -> ARRAY<STRUCT> (pas de clé, longueur variable :
#     rien à pivoter, et l'imbrication évite de dupliquer l'issue autant de fois
#     qu'elle a de commentaires)
# ---------------------------------------------------------------------------


def _normaliser_nom_colonne(nom):
    """Transforme un nom de champ Jira en identifiant de colonne BigQuery.

    Reprend la convention de l'ancienne Cloud Function (dataset `pspc`) pour que
    les utilisateurs retrouvent les noms qu'ils connaissent : accents retirés,
    tout caractère non alphanumérique remplacé par un underscore.
    « N° prélèvement » devient « N__prelevement ».
    """
    decompose = unicodedata.normalize("NFKD", nom)
    sans_accent = "".join(c for c in decompose if not unicodedata.combining(c))
    colonne = re.sub(r"[^0-9a-zA-Z_]", "_", sans_accent)
    # Un identifiant BigQuery ne peut pas commencer par un chiffre.
    if not colonne or colonne[0].isdigit():
        colonne = "_" + colonne
    return colonne[:300]  # limite BigQuery


def _litteral_sql(valeur):
    """Échappe une chaîne pour l'insérer dans un littéral SQL entre apostrophes."""
    return valeur.replace("\\", "\\\\").replace("'", "\\'")


def _colonnes_pivot(champs):
    """Construit une expression de colonne par champ personnalisé.

    `champs` est une liste de (nom_du_champ, [ids du customfield]).

    Deux précautions :
      - les champs homonymes (même nom, plusieurs customfield.id) sont suffixés
        par leur id. Sur PSPC, deux jeux d'options distincts remontent tous deux
        sous « Année » : sans ce suffixe, ils fusionneraient silencieusement.
      - STRING_AGG et non MAX : quelques champs sont multivalués (une issue peut
        porter deux « Méthode d'analyse réalisée »). MAX en perdrait une sans
        prévenir. Sur un champ monovalué, le résultat est la valeur elle-même.
    """
    expressions = []
    deja_vus = {}
    for nom, ids in champs:
        base = _normaliser_nom_colonne(nom)
        # Un seul customfield derrière ce nom : colonne au nom simple.
        # Plusieurs : une colonne par id, pour ne rien fusionner à l'aveugle.
        cibles = [(base, None)] if len(ids) <= 1 else [(f"{base}__{i}", i) for i in ids]
        for colonne, field_id in cibles:
            # Deux noms de champs différents peuvent se normaliser vers le même
            # identifiant (« N° lot » et « N. lot ») : on suffixe pour éviter une
            # erreur de colonne dupliquée à la création de la vue.
            deja_vus[colonne] = deja_vus.get(colonne, 0) + 1
            if deja_vus[colonne] > 1:
                colonne = f"{colonne}_{deja_vus[colonne]}"
            predicat = f"field = '{_litteral_sql(nom)}'"
            if field_id is not None:
                predicat += f" AND field_id = {field_id}"
            expressions.append(
                f"    STRING_AGG(IF({predicat}, valeur, NULL), ' | ' ORDER BY valeur)"
                f" AS `{colonne}`"
            )
    return expressions


def _lister_champs(client, ref_table_cf):
    """Champs personnalisés présents dans le run qui vient de se terminer."""
    requete = f"""
        SELECT field, ARRAY_AGG(DISTINCT field_id IGNORE NULLS ORDER BY field_id) AS field_ids
        FROM `{ref_table_cf}`
        WHERE field IS NOT NULL
        GROUP BY field
        ORDER BY field
    """
    return [(ligne["field"], list(ligne["field_ids"])) for ligne in client.query(requete).result()]


# Colonnes ajoutées par dlt, ou déjà portées par l'issue elle-même : elles n'ont
# rien à faire dans les STRUCT imbriqués de la vue.
COLONNES_TECHNIQUES = {"_dlt_id", "_dlt_parent_id", "_dlt_list_idx", "issue_id", "issue_cle"}


def creer_vue_issues(bq_project_id, bq_dataset_id, bq_table_id):
    """Crée (ou remplace) la vue `v_issues` du dataset."""
    from google.cloud import bigquery

    client = bigquery.Client(project=bq_project_id)
    prefixe = f"{bq_project_id}.{bq_dataset_id}"
    tables = {t.table_id for t in client.list_tables(prefixe)}

    if bq_table_id not in tables:
        logging.warning(
            f"Table {bq_table_id} absente du dataset {bq_dataset_id} : vue non créée"
        )
        return

    ctes = []
    selections = ["    i.* EXCEPT (_dlt_id, _dlt_load_id)"]
    jointures = []

    table_cf = f"{bq_table_id}__custom_fields"
    if table_cf in tables:
        champs = _lister_champs(client, f"{prefixe}.{table_cf}")
        if champs:
            colonnes = _colonnes_pivot(champs)
            ctes.append(
                "champs AS (\n  SELECT\n    issue_id,\n"
                + ",\n".join(colonnes)
                + f"\n  FROM `{prefixe}.{table_cf}`\n  GROUP BY issue_id\n)"
            )
            selections.append("    champs.* EXCEPT (issue_id)")
            jointures.append("LEFT JOIN champs ON champs.issue_id = i.id")
            logging.info(
                f"Vue v_issues : {len(colonnes)} colonnes de champs personnalisés"
            )
        else:
            logging.info(
                f"Aucun champ personnalisé dans {table_cf} : vue sans colonne pivotée"
            )

    # Commentaires et journal des modifications : imbriqués, pas pivotés.
    #
    # Pré-agrégés dans une CTE plutôt qu'en sous-requête corrélée. La forme
    # naturelle, `ARRAY(SELECT AS STRUCT ... WHERE e.issue_id = i.id ORDER BY ...)`,
    # est rejetée par BigQuery : « Correlated subqueries that reference other
    # tables are not supported unless they can be de-correlated ». Sans le
    # ORDER BY la corrélation passe, mais l'ordre chronologique du journal ne
    # serait plus garanti — et un GROUP BY coûte de toute façon moins qu'une
    # corrélation réévaluée pour chaque issue.
    for nom_bloc, suffixe, tri in (
        ("commentaires", "__commentaires", "create_date"),
        ("changelog", "__changelog", "date"),
    ):
        table_enfant = f"{bq_table_id}{suffixe}"
        if table_enfant not in tables:
            logging.warning(f"Table {table_enfant} absente : {nom_bloc} omis de la vue")
            continue
        colonnes_enfant = [
            colonne.name
            for colonne in client.get_table(f"{prefixe}.{table_enfant}").schema
            if colonne.name not in COLONNES_TECHNIQUES
        ]
        if not colonnes_enfant:
            continue
        struct = ", ".join(f"`{c}`" for c in colonnes_enfant)
        ordre = f" ORDER BY `{tri}`" if tri in colonnes_enfant else ""
        ctes.append(
            f"agg_{nom_bloc} AS (\n"
            f"  SELECT issue_id, ARRAY_AGG(STRUCT({struct}){ordre}) AS {nom_bloc}\n"
            f"  FROM `{prefixe}.{table_enfant}`\n"
            f"  GROUP BY issue_id\n"
            f")"
        )
        # Une issue sans commentaire ressortirait à NULL via le LEFT JOIN : un
        # tableau vide est plus simple à consommer.
        selections.append(f"    IFNULL(agg_{nom_bloc}.{nom_bloc}, []) AS {nom_bloc}")
        jointures.append(f"LEFT JOIN agg_{nom_bloc} ON agg_{nom_bloc}.issue_id = i.id")

    requete = f"CREATE OR REPLACE VIEW `{prefixe}.v_issues` AS\n"
    if ctes:
        requete += "WITH " + ",\n".join(ctes) + "\n"
    requete += "SELECT\n" + ",\n".join(selections)
    requete += f"\nFROM `{prefixe}.{bq_table_id}` i\n"
    if jointures:
        requete += "\n".join(jointures) + "\n"

    logging.debug(f"SQL de la vue :\n{requete}")
    client.query(requete).result()
    logging.info(f"Vue `{prefixe}.v_issues` créée")

def load_jira_data():
    """
    Pipeline dlt pour exporter JIRA de PostgreSQL vers BigQuery.
    """
    # Configuration PostgreSQL
    secret_url = os.environ.get("PG_URL_SECRET")
    client = secretmanager.SecretManagerServiceClient()
    response = client.access_secret_version(request={"name": secret_url})
    pg_url_secret = response.payload.data.decode("UTF-8")
    # postgresql://user:password@ip:port/schema?options=-c%20search_path%3Dschema

    # Configuration JIRA
    jira_project_key = os.getenv('JIRA_PROJECT_KEY')
    
    # Configuration BigQuery
    bq_dataset_id = os.getenv('BQ_DATASET_ID')
    if bq_dataset_id:
        bq_dataset_id = bq_dataset_id.lower()
    if not bq_dataset_id:
        if not jira_project_key:
            logging.error("JIRA_PROJECT_KEY n'est pas défini et BQ_DATASET_ID n'est pas fourni. Impossible de générer un nom de dataset.")
            sys.exit(1)
        bq_dataset_id = f'jira_{jira_project_key.lower()}'
    bq_table_id = os.getenv('BQ_TABLE_ID', 'issues')

    google_cloud_project = os.getenv('GOOGLE_CLOUD_PROJECT')
    bq_project_id = os.getenv('BQ_PROJECT_ID')
    if not bq_project_id:
        if not google_cloud_project:
            logging.error("BQ_PROJECT_ID n'est pas fourni et GOOGLE_CLOUD_PROJECT n'est pas défini. Impossible de savoir où créer la ressource")
            sys.exit(1)
        bq_project_id = google_cloud_project
    
    required_vars = [
        ('PG_URL_SECRET', pg_url_secret),
        ('BQ_TABLE_ID', bq_table_id),
    ]
    
    for var_name, var_value in required_vars:
        if not var_value:
            logging.error(f"{var_name} n'est pas défini")
            sys.exit(1)
    
    logging.info(f"Début de l'export JIRA vers BigQuery - Projet: {jira_project_key}")
    
    try:
        # Lire la requête SQL
        with open('request.sql', 'r', encoding='utf-8') as f:
            sql_query = f.read()
        
        logging.info("Fichier request.sql chargé")

        # Créer la pipeline dlt
        logging.info("Initialisation de la pipeline dlt")
        
        destination_params = {"location": "EU"}
        if bq_project_id:
            destination_params["project_id"] = bq_project_id

        pipeline = dlt.pipeline(
            pipeline_name='jira_to_bq',
            destination=dlt.destinations.bigquery(**destination_params),
            dataset_name=bq_dataset_id,
            # dlt crée automatiquement le dataset s'il n'existe pas
        )
        
        # Créer la ressource avec custom SQL
        # custom_fields.value est un COALESCE(stringvalue, numbervalue::text,
        # textvalue, datevalue::text) : du texte libre, des nombres et des dates
        # dans une seule colonne. Sans ce hint, dlt en infère le type d'après les
        # premières valeurs vues — timestamp dès qu'il croise des datevalue ISO
        # (le détecteur iso_timestamp est actif par défaut) — et le résultat
        # dépend alors du projet Jira :
        #   - les nombres sont convertis en dates absurdes (an 0078, an 9908) ;
        #   - un nombre hors bornes fait échouer tout le run en step=normalize
        #     (pendulum.from_timestamp -> OSError [Errno 75], vu sur IMP).
        # On force donc le type en text : cette colonne n'est pas une date.
        @dlt.resource(table_name=bq_table_id,
                      write_disposition="replace",
                      max_table_nesting=2,
                      nested_hints={
                          "custom_fields": make_nested_hints(
                              columns=[
                                  {"name": "value", "data_type": "text"},
                                  {"name": "valeur", "data_type": "text"},
                              ]
                          )
                      })
        def jira_issues():
            """Récupère les issues JIRA de PostgreSQL."""
            import psycopg2

            logging.info(f"Connexion à la base de données pour le projet: {jira_project_key}")
            try:
                conn = psycopg2.connect(pg_url_secret, connect_timeout=30)
                logging.info("Connexion PostgreSQL établie avec succès")
            except Exception as e:
                logging.error(f"Échec de la connexion PostgreSQL : {e}")
                raise e
            
            try:
                with conn.cursor() as cursor:
                    logging.info("Curseur obtenu, lancement de la requête...")
                    cursor.execute(sql_query, (jira_project_key,))
                    
                    # Récupérer les colonnes
                    columns = [desc[0] for desc in cursor.description]
                    logging.info(f"Colonnes trouvées: {len(columns)}")
                    
                    # Yielder les données
                    row_count = 0
                    for row in cursor.fetchall():
                        yield dict(zip(columns, row))
                        row_count += 1
                    
                    logging.info(f"Nombre de lignes extraites: {row_count}")
            finally:
                conn.close()
        
        # Exécuter la pipeline
        logging.info("Lancement de la pipeline dlt")
        load_info = pipeline.run(jira_issues())

        logging.info("Export terminé avec succès")

        # La vue est créée après coup, à partir des données réellement chargées.
        # Un échec ici ne remet pas en cause le chargement, qui est l'essentiel :
        # on journalise sans faire échouer le job, sinon un CronJob vert deviendrait
        # rouge alors que la donnée est bien arrivée.
        try:
            creer_vue_issues(bq_project_id, bq_dataset_id, bq_table_id)
        except Exception as e:
            logging.error(f"Création de la vue v_issues impossible : {e}", exc_info=True)
        
    except FileNotFoundError as e:
        logging.error(f"Fichier request.sql non trouvé: {e}")
        sys.exit(1)
    except Exception as e:
        logging.error(f"Erreur lors de l'export: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    load_jira_data()
