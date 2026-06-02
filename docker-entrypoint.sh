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
mkdir -p /data/.gbrain

# ─── gbrain provider env ──────────────────────────────────────────────
# Use litellm provider. Do NOT set OPENAI_API_KEY — that triggers
# gbrain's auto-detect to pick openai for chat/expansion, which we don't want.
export LITELLM_BASE_URL="http://localhost:4000"
export LITELLM_API_KEY="$LITELLM_MASTER_KEY"

# ─── Pre-write gbrain config.json ─────────────────────────────────────
# CRÍTICO: los campos schema-stable (embedding_model, embedding_dimensions,
# chat_model, expansion_model, provider_base_urls) van SOLO en este archivo.
# gbrain config set solo afecta tier routing (models.tier.*).
#
# embedding_dimensions: 1536 = MRL truncation point de qwen3-embedding.
# Encaja con vector(1536) default de gbrain, sin DDL surgery.
# La truncación MRL real ocurre en LiteLLM via extra_body.dimensions: 1536.
cat > /data/.gbrain/config.json <<EOF
{
  "engine": "pglite",
  "database_path": "/data/.gbrain/brain.pglite",
  "embedding_model": "litellm:qwen3-embedding",
  "embedding_dimensions": 1536,
  "chat_model": "litellm:gemma4",
  "expansion_model": "litellm:gemma4",
  "provider_base_urls": {
    "litellm": "http://localhost:4000"
  }
}
EOF
echo "[entrypoint] gbrain config written to /data/.gbrain/config.json"

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

# ─── gbrain init (PGLite) ─────────────────────────────────────────────
# Sin flags: gbrain lee /data/.gbrain/config.json que ya está escrito.
# --yes para non-interactive confirmation.
echo "[entrypoint] Initializing gbrain PGLite brain..."
gbrain init --pglite --yes
echo "[entrypoint] Running gbrain migrations..."
gbrain apply-migrations --yes --non-interactive

# ─── Apply tier routing (DB-backed, Anthropic names; shim translates) ─
# gbrain internamente usa el recipe anthropic para chat. El shim reescribe
# paths /messages → /v1/messages y LiteLLM traduce el body.
echo "[entrypoint] Applying tier routing..."
gbrain config set models.default claude-sonnet-4-6 2>/dev/null || true
gbrain config set models.tier.utility claude-haiku-4-5-20251001 2>/dev/null || true
gbrain config set models.tier.reasoning claude-sonnet-4-6 2>/dev/null || true
gbrain config set models.tier.deep claude-sonnet-4-6 2>/dev/null || true

# ─── Runtime env for gbrain serve ─────────────────────────────────────
# gbrain's Anthropic SDK calls go through the shim, which forwards to LiteLLM.
export ANTHROPIC_BASE_URL="http://localhost:4001"
export ANTHROPIC_API_KEY="$LITELLM_MASTER_KEY"

# ─── Start nginx reverse proxy ────────────────────────────────────────
echo "[entrypoint] Starting nginx on :80..."
nginx -g 'daemon off;' &

# ─── Build command with optional flags ────────────────────────────────
GBRAIN_CMD=("$@")
if [ -n "$PUBLIC_URL" ]; then
  GBRAIN_CMD+=("--public-url" "$PUBLIC_URL")
fi

# ─── Execute the command ──────────────────────────────────────────────
echo "[entrypoint] Starting: ${GBRAIN_CMD[*]}"
exec "${GBRAIN_CMD[@]}"
