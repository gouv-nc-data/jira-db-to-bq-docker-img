FROM ghcr.io/astral-sh/uv:python3.13-trixie-slim

WORKDIR /app

COPY main.py .

RUN uv sync --locked

CMD ["uv", "run", "python", "main.py"]