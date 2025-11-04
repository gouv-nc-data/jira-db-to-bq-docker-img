FROM ghcr.io/astral-sh/uv:python3.13-trixie-slim

WORKDIR /app

# 1. Copiez D'ABORD uniquement les fichiers de dépendances.
COPY pyproject.toml uv.lock ./

# 2. Installez les dépendances.
# Cette couche sera mise en cache tant que vos dépendances (toml/lock) ne changent pas.
RUN uv sync --locked

# 3. Copiez ENSUITE le reste du code de votre application.
COPY request.sql .
COPY main.py .

# user non-root
USER 1000

CMD ["uv", "run", "python", "main.py"]