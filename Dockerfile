FROM elixir:1.19

ARG CODEX_NPM_PACKAGE_VERSION=0.120.0

ENV MIX_ENV=prod \
    HOME=/data/home \
    KEPLER_CONFIG_PATH=/app/elixir/kepler.yml \
    KEPLER_WORKSPACE_ROOT=/data/workspaces \
    KEPLER_STATE_ROOT=/data/state \
    CODEX_BIN=codex

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    npm \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@openai/codex@${CODEX_NPM_PACKAGE_VERSION}"

WORKDIR /app/elixir

COPY elixir/mix.exs elixir/mix.lock ./
COPY elixir/config ./config

RUN mix local.hex --force \
 && mix local.rebar --force \
 && mix deps.get --only prod

COPY elixir ./

RUN chmod +x ./scripts/run-kepler.sh ./scripts/docker-entrypoint.sh \
 && mix build

EXPOSE 4040

ENTRYPOINT ["./scripts/docker-entrypoint.sh"]
