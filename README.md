# jira-to-bq-cloud-run-template

Pipeline d'export des issues JIRA depuis PostgreSQL vers BigQuery utilisant **dlt** et **uv**.

## Fichiers principaux

| Fichier | Description |
|---------|-------------|
| `main.py` | Pipeline dlt pour exporter JIRA → BigQuery |
| `request.sql` | Requête SQL avec extraction complète des issues JIRA |
| `pyproject.toml` | Dépendances gérées avec `uv` |
| `Dockerfile` | Container optimisé pour Cloud Run |
| `.env.example` | Exemple de configuration |

## Configuration

Copier `.env.example` en `.env` et remplir les variables:

```bash
cp .env.example .env
```

### Variables obligatoires

- `POSTGRES_PASSWORD` - Mot de passe PostgreSQL
- `JIRA_PROJECT_KEY` - Clé du projet JIRA (ex: `SIN`)

### Variables optionnelles

- `POSTGRES_HOST` (défaut: `localhost`)
- `POSTGRES_PORT` (défaut: `5432`)
- `POSTGRES_USER` (défaut: `postgres`)
- `POSTGRES_DB` (défaut: `jira`)
- `BQ_DATASET_ID` (défaut: `jira_export`)
- `BQ_TABLE_ID` (défaut: `issues`)

## Utilisation

### Local avec uv

```bash
uv sync
uv run python main.py
```

### Docker

```bash
docker build -t jira-to-bq .
docker run \
  -e POSTGRES_PASSWORD=pwd \
  -e JIRA_PROJECT_KEY=SIN \
  jira-to-bq
```

## Dépendances

- **dlt[postgres,bigquery]** - Pipeline d'ETL
- **loguru** - Logging structuré (visible sur GCP Cloud Logging)
- **python-dotenv** - Gestion des variables d'env

Gérées avec **uv** (pas de pip)

## Logs et monitoring

Les logs générés par `loguru` apparaissent automatiquement dans **Google Cloud Logging** :

```bash
# Afficher les logs du service
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=jira-to-bq" --limit=50

# Voir les erreurs
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=jira-to-bq AND severity=ERROR"
```

Voir `LOGS_GCP.md` pour plus de détails.

## Licence

Voir LICENSE