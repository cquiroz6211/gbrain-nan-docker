#!/bin/bash
set -e

# ─── Validate required env vars ───────────────────────────────────────
for var in NAN_API_KEY LITELLM_MASTER_KEY; do
  if [ -z "${!var}" ]; then
    echo "ERROR: $var is not set" >&2
    exit 1
  fi
done

# ─── Setup persistent storage ─────────────────────────────────────────
mkdir -p /data
export HOME="/data"

# ─── First-run gbrain init (PGLite) ───────────────────────────────────
if [ ! -f "/data/.gbrain/config.json" ]; then
  echo "[entrypoint] First run: initializing gbrain PGLite brain..."
  # Set env so gbrain picks litellm as embed provider at init time.
  # The actual API calls happen later when embed/import runs.
  export LITELLM_BASE_URL="http://localhost:4000"
  export LITELLM_API_KEY="$LITELLM_MASTER_KEY"
  export OPENAI_API_KEY="$LITELLM_MASTER_KEY"
  export OPENAI_BASE_URL="http://localhost:4000"
  gbrain init --pglite \
    --embedding-model litellm:qwen3-embedding \
    --embedding-dimensions 4096 \
    --yes
  gbrain apply-migrations --yes --non-interactive
fi

# ─── Export runtime env ───────────────────────────────────────────────
export LITELLM_BASE_URL="http://localhost:4000"
export LITELLM_API_KEY="$LITELLM_MASTER_KEY"
export OPENAI_API_KEY="$LITELLM_MASTER_KEY"
export OPENAI_BASE_URL="http://localhost:4000"
export ANTHROPIC_BASE_URL="http://localhost:4001"
export ANTHROPIC_API_KEY="$LITELLM_MASTER_KEY"

# ─── Start LiteLLM proxy ──────────────────────────────────────────────
echo "[entrypoint] Starting LiteLLM on :4000..."
litellm --config /etc/gbrain/litellm/config.yaml --port 4000 --telemetry False &
LITELLM_PID=$!

echo "[entrypoint] Waiting for LiteLLM..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:4000/health/liveness >/dev/null 2>&1; then
    echo "[entrypoint] LiteLLM is ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "[entrypoint] ERROR: LiteLLM did not start" >&2
    exit 1
  fi
  sleep 1
done

# ─── Start anthropic-shim ─────────────────────────────────────────────
echo "[entrypoint] Starting anthropic-shim on :4001..."
bun run /etc/gbrain/litellm/anthropic-shim.ts &
SHIM_PID=$!

echo "[entrypoint] Waiting for anthropic-shim..."
for i in $(seq 1 30); do
  if curl -sf -o /dev/null -w "%{http_code}" http://localhost:4001/ 2>/dev/null | grep -qE '^[23]'; then
    echo "[entrypoint] anthropic-shim is ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "[entrypoint] ERROR: anthropic-shim did not start" >&2
    exit 1
  fi
  sleep 1
done

# ─── Apply tier routing (DB-backed) ───────────────────────────────────
# gbrain internally uses Anthropic model names; LiteLLM translates to nan.
echo "[entrypoint] Applying tier routing..."
gbrain config set models.default claude-sonnet-4-6 2>/dev/null || true
gbrain config set models.tier.utility claude-haiku-4-5-20251001 2>/dev/null || true
gbrain config set models.tier.reasoning claude-sonnet-4-6 2>/dev/null || true
gbrain config set models.tier.deep claude-sonnet-4-6 2>/dev/null || true

# ─── Build command with optional flags ────────────────────────────────
GBRAIN_CMD=("$@")
if [ -n "$PUBLIC_URL" ]; then
  GBRAIN_CMD+=("--public-url" "$PUBLIC_URL")
fi

# ─── Execute the command ──────────────────────────────────────────────
echo "[entrypoint] Starting: ${GBRAIN_CMD[*]}"
exec "${GBRAIN_CMD[@]}"
