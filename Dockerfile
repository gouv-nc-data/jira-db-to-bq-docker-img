FROM ghcr.io/astral-sh/uv:python3.13-trixie-slim

WORKDIR /app

# Configuration pour optimiser le cache uv
ENV UV_LINK_MODE=copy
ENV UV_COMPILE_BYTECODE=1
ENV UV_NO_CACHE=1

# 1. Copiez D'ABORD uniquement les fichiers de dépendances.
COPY pyproject.toml uv.lock ./

# 2. Installez les dépendances uniquement (sans le projet).
# Cette couche sera mise en cache tant que vos dépendances (toml/lock) ne changent pas.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-install-project

# 3. Copiez ENSUITE le reste du code de votre application.
COPY request.sql .
COPY main.py .

# 4. Sync le projet complet
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked

# user non-root
USER 1000

CMD ["uv", "run", "python", "main.py"]