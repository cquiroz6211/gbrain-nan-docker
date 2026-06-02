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

# ─── gbrain provider env ──────────────────────────────────────────────
# Use litellm provider (NOT openai). Do NOT set OPENAI_API_KEY or
# OPENAI_BASE_URL — that triggers gbrain's auto-detect to pick openai
# for chat/expansion, which we don't want.
export LITELLM_BASE_URL="http://localhost:4000"
export LITELLM_API_KEY="$LITELLM_MASTER_KEY"

# ─── Start LiteLLM proxy FIRST ────────────────────────────────────────
# gbrain init needs LiteLLM up so it can probe the embedding model.
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

# ─── First-run gbrain init (PGLite) ───────────────────────────────────
# --embedding-dimensions 4096 is required for user-driven-model recipes
# (litellm, llama-server): gbrain has no default for them and refuses to
# probe. qwen3-embedding on nan returns a fixed 4096d vector.
if [ ! -f "/data/.gbrain/config.json" ]; then
  echo "[entrypoint] First run: initializing gbrain PGLite brain..."
  gbrain init --pglite \
    --embedding-model litellm:qwen3-embedding \
    --embedding-dimensions 4096 \
    --yes
  gbrain apply-migrations --yes --non-interactive
fi

# ─── Override chat/expansion to use litellm provider ──────────────────
# The init's auto-detect may have picked openai:gpt-5.2 (from OPENAI_API_KEY
# in the env if any leaked through). Force everything to litellm.
echo "[entrypoint] Setting chat/expansion models..."
gbrain config set chat_model litellm:qwen3.6 2>/dev/null || true
gbrain config set expansion_model litellm:qwen3.6 2>/dev/null || true

# ─── Apply tier routing (Anthropic model names; LiteLLM translates) ──
echo "[entrypoint] Applying tier routing..."
gbrain config set models.default claude-sonnet-4-6 2>/dev/null || true
gbrain config set models.tier.utility claude-haiku-4-5-20251001 2>/dev/null || true
gbrain config set models.tier.reasoning claude-sonnet-4-6 2>/dev/null || true
gbrain config set models.tier.deep claude-sonnet-4-6 2>/dev/null || true

# ─── Runtime env for gbrain serve ─────────────────────────────────────
# gbrain's Anthropic SDK calls go through the shim, which forwards to LiteLLM.
export ANTHROPIC_BASE_URL="http://localhost:4001"
export ANTHROPIC_API_KEY="$LITELLM_MASTER_KEY"

# ─── Build command with optional flags ────────────────────────────────
GBRAIN_CMD=("$@")
if [ -n "$PUBLIC_URL" ]; then
  GBRAIN_CMD+=("--public-url" "$PUBLIC_URL")
fi

# ─── Execute the command ──────────────────────────────────────────────
echo "[entrypoint] Starting: ${GBRAIN_CMD[*]}"
exec "${GBRAIN_CMD[@]}"
