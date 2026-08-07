#!/bin/bash
# Real-model smoke against NVIDIA's OpenAI-compatible endpoint.
# Needs NVIDIA_API_KEY in the repo-root .env (never printed, never committed).
set -euo pipefail

export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export RUBYOPT="-Eutf-8"

XENO_PATH="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$XENO_PATH/../.env"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

cd "$XENO_PATH"
bin/rails test test/smoke/real_model_smoke_test.rb "$@"
