#!/usr/bin/env sh
set -eu

APP_ROOT="${APP_ROOT:-/app/elixir}"
CONFIG_PATH="${KEPLER_CONFIG_PATH:-$APP_ROOT/kepler.yml}"
PORT_VALUE="${PORT:-4040}"
CODEX_COMMAND="${CODEX_BIN:-codex}"

export HOME="${HOME:-/data/home}"
export KEPLER_CONFIG_PATH="$CONFIG_PATH"
export KEPLER_WORKSPACE_ROOT="${KEPLER_WORKSPACE_ROOT:-/data/workspaces}"
export KEPLER_STATE_ROOT="${KEPLER_STATE_ROOT:-/data/state}"
export CODEX_BIN="$CODEX_COMMAND"

mkdir -p "$HOME" "$KEPLER_WORKSPACE_ROOT" "$KEPLER_STATE_ROOT"

if [ -n "${GITHUB_APP_PRIVATE_KEY_BASE64:-}" ] && [ -z "${GITHUB_APP_PRIVATE_KEY:-}" ]; then
  export GITHUB_APP_PRIVATE_KEY="$(printf '%s' "$GITHUB_APP_PRIVATE_KEY_BASE64" | base64 -d)"
fi

if [ ! -f "$CONFIG_PATH" ]; then
  echo "Kepler config file not found at $CONFIG_PATH" >&2
  exit 1
fi

if ! command -v "$CODEX_COMMAND" >/dev/null 2>&1; then
  echo "CODEX_BIN command not found: $CODEX_COMMAND" >&2
  exit 1
fi

if [ "$CODEX_COMMAND" = "codex" ] || [ "$(basename "$CODEX_COMMAND")" = "codex" ]; then
  if ! codex login status >/dev/null 2>&1; then
    if [ -z "${OPENAI_API_KEY:-}" ]; then
      echo "OPENAI_API_KEY is required so codex can authenticate non-interactively at container startup." >&2
      exit 1
    fi

    printf '%s' "$OPENAI_API_KEY" | codex login --with-api-key >/dev/null
  fi
fi

cd "$APP_ROOT"
exec ./scripts/run-kepler.sh --port "$PORT_VALUE"
