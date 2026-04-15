#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${KEPLER_ENV_FILE:-$ROOT_DIR/.env.kepler}"
CONFIG_PATH="${KEPLER_CONFIG_PATH:-$ROOT_DIR/kepler.yml}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

cd "$ROOT_DIR"
exec ./bin/symphony kepler \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --config "$CONFIG_PATH" \
  "$@"
