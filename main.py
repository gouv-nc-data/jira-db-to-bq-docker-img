import os
import sys
from urllib import response

import dlt
from dlt.sources.sql_database import sql_database
from loguru import logger
from dotenv import load_dotenv
from google.cloud import secretmanager

load_dotenv()

logger.remove()  # Supprimer le handler par défaut
logger.add(
    sys.stdout,
    format="<level>{level: <8}</level> | <cyan>{name}</cyan>:<cyan>{function}</cyan> - <level>{message}</level>",
    level="INFO",
)

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
    bq_dataset_id = os.getenv('BQ_DATASET_ID', 'jira_export')
    bq_table_id = os.getenv('BQ_TABLE_ID', 'issues')
    bq_project_id = os.getenv('BQ_PROJECT_ID')
    
    required_vars = [
        ('PG_URL_SECRET', pg_url_secret),
        ('JIRA_PROJECT_KEY', jira_project_key),
        ('BQ_DATASET_ID', bq_dataset_id),
        ('BQ_TABLE_ID', bq_table_id),
    ]
    
    for var_name, var_value in required_vars:
        if not var_value:
            logger.error(f"{var_name} n'est pas défini")
            sys.exit(1)
    
    logger.info(f"Début de l'export JIRA vers BigQuery - Projet: {jira_project_key}")
    
    try:
        # Lire la requête SQL
        with open('request.sql', 'r', encoding='utf-8') as f:
            sql_query = f.read()
        
        logger.info("Fichier request.sql chargé")
        
        # Créer la pipeline dlt
        logger.info("Initialisation de la pipeline dlt")
        
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
        @dlt.resource(table_name=bq_table_id,
                      write_disposition="replace",
                      max_table_nesting=2)
        def jira_issues():
            """Récupère les issues JIRA de PostgreSQL."""
            import psycopg2

            logger.info(f"Connexion à la base de données pour le projet: {jira_project_key}")
            try:
                conn = psycopg2.connect(pg_url_secret, connect_timeout=30)
                logger.info("Connexion PostgreSQL établie avec succès")
            except Exception as e:
                logger.error(f"Échec de la connexion PostgreSQL : {e}")
                raise e
            
            try:
                with conn.cursor() as cursor:
                    logger.info("Curseur obtenu, lancement de la requête...")
                    cursor.execute(sql_query, (jira_project_key,))
                    
                    # Récupérer les colonnes
                    columns = [desc[0] for desc in cursor.description]
                    logger.info(f"Colonnes trouvées: {len(columns)}")
                    
                    # Yielder les données
                    row_count = 0
                    for row in cursor.fetchall():
                        yield dict(zip(columns, row))
                        row_count += 1
                    
                    logger.info(f"Nombre de lignes extraites: {row_count}")
            finally:
                conn.close()
        
        # Exécuter la pipeline
        logger.info("Lancement de la pipeline dlt")
        load_info = pipeline.run(jira_issues())
        
        logger.info("Export terminé avec succès")
        
    except FileNotFoundError as e:
        logger.error(f"Fichier request.sql non trouvé: {e}")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Erreur lors de l'export: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    load_jira_data()
