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
- `BQ_PROJECT_ID` (optionnel: ID du projet GCP de destination si différent du projet d'exécution)

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

## Schéma produit dans BigQuery

dlt écrit une table `issues` (une ligne par issue) et une table par tableau
imbriqué : `issues__custom_fields`, `issues__commentaires`, `issues__changelog`,
`issues__liens`, `issues__pieces_jointes`, `issues__etiquettes`.

### Rattacher un enfant à son issue

Toutes les tables enfants portent `issue_id` (l'id Jira) et `issue_cle`
(`PSPC-447`). C'est la clé de jointure à utiliser :

```sql
SELECT i.cle, i.resume, c.auteur, c.create_date, c.description
FROM `projet.jira_pspc.issues` i
JOIN `projet.jira_pspc.issues__commentaires` c USING (issue_id)
```

Ne **pas** joindre sur `_dlt_parent_id` / `_dlt_id` : ce sont des identifiants
techniques de dlt, régénérés à chaque exécution puisque le pipeline tourne en
`replace`. Une table dérivée qui s'appuie dessus cesse de correspondre au run
suivant.

### Champs personnalisés : lire `valeur`

`issues__custom_fields` expose quatre colonnes utiles :

| Colonne | Contenu |
|---|---|
| `field` | nom du champ (`Commune`) |
| `field_id` | id du customfield Jira, pour distinguer deux champs homonymes |
| `valeur` | **la valeur lisible** (`Nouméa`) — c'est celle à utiliser |
| `value` / `option` | valeurs brutes de la base Jira, conservées pour référence |

Pour un champ à liste de choix, `value` contient l'id interne de l'option
(`38885`) et non son libellé, qui vit dans `option`. `valeur` applique le
`COALESCE` une fois pour toutes.

### La vue `v_issues`

Créée automatiquement à la fin de chaque exécution, elle donne **une ligne par
issue** avec :

- les champs standards de l'issue, dont `cle` (`PSPC-447`) ;
- **un champ personnalisé par colonne**, nommé comme le champ Jira sans accent
  ni caractère spécial (`N° prélèvement` devient `N__prelevement`). Un champ
  multivalué est rendu `valeur1 | valeur2` ;
- `commentaires` et `changelog` en `ARRAY<STRUCT>`, triés chronologiquement.

C'est le point d'entrée conseillé pour Looker Studio ou un export tableur — en
excluant les deux colonnes `ARRAY`, que ces outils ne savent pas lire. Pour les
exploiter en SQL :

```sql
SELECT cle, Commune, c.auteur, c.description
FROM `projet.jira_pspc.v_issues`, UNNEST(commentaires) AS c
```

La liste des colonnes est régénérée à chaque exécution à partir des champs
réellement présents : un nouveau champ ajouté dans Jira apparaît tout seul.

## Licence

Voir LICENSE