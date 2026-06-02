# gbrain-nan-docker

Deploy [gbrain](https://github.com/garrytan/gbrain) con [api.nan.builders](https://api.nan.builders) como proveedor de IA, todo en un solo contenedor.

## Stack

| Componente | Rol |
|---|---|
| **gbrain** | Cerebro persistente para agentes de IA (MCP + admin dashboard) |
| **PGLite** | Postgres 17 embebido vía WASM (engine default de gbrain, zero-config) |
| **LiteLLM** | Proxy que traduce OpenAI-compatible → nan.builders |
| **anthropic-shim** | Normalizador de paths para los SDKs Anthropic que usa gbrain |
| **bun** | Runtime para gbrain + shim |

## Por qué PGLite y no un servidor PostgreSQL

La versión anterior de este proyecto embebía un servidor PostgreSQL dentro del contenedor. Eso falla en la mayoría de los PaaS (Railway, Render, Fly, etc.) por tres razones:

1. `/dev/shm` chiquito (64 MB default) — PostgreSQL necesita memoria compartida POSIX.
2. Sin `shm_size` configurable, no se puede arrancar.
3. `postgresql-17` no está en los repos oficiales de Debian (la imagen base `oven/bun:1` es bookworm, que trae `postgresql-15`).

**PGLite** es Postgres 17.5 compilado a WASM, embebido en el mismo proceso de gbrain. Cero infraestructura, cero puertos, cero shm, cero initdb. Es el engine default oficial de gbrain desde v0.7. El `gbrain init --pglite` arranca en 2 segundos y guarda todo en `/data/.gbrain/brain.db`.

## Requisitos

- Un PaaS que detecte Dockerfile y construya desde GitHub (Railway, Render, Fly, etc.)
- API key de [api.nan.builders](https://api.nan.builders)
- Volumen persistente montado en `/data` (configuralo en tu PaaS)

## Despliegue local

```bash
cp .env.example .env
# Editar .env con tu NAN_API_KEY y LITELLM_MASTER_KEY
docker compose up -d
```

- **Admin dashboard**: `http://localhost:8080/admin/`
- **MCP endpoint**: `http://localhost:8080/mcp`
- **Health**: `http://localhost:8080/health`

Los datos persisten en el volumen `gbrain-data` montado en `/data`:

```
/data/
└── .gbrain/
    ├── brain.db            ← PGLite database (pages, chunks, embeddings, links)
    └── config.json         ← gbrain config (engine, models, dimensions, etc.)
```

## Configuración

### `.env`

```env
NAN_API_KEY=sk-...                          # Tu API key de nan.builders (obligatorio)
LITELLM_MASTER_KEY=sk-local-...            # Clave maestra del proxy LiteLLM (obligatorio)
PUBLIC_URL=https://gbrain.tudominio.com    # Opcional. Para exponer con HTTPS
```

### Modelos

| Tier gbrain | nan.builders | Uso |
|---|---|---|
| `claude-opus-4-7` (reasoning, deep) | `deepseek-v4-flash` | Razonamiento profundo |
| `claude-sonnet-4-6` (default) | `qwen3.6` | Chat default |
| `claude-haiku-4-5-20251001` (utility) | `gemma4` | Tareas ligeras |
| — | `qwen3-embedding` (4096d) | Embeddings |

> **Nota sobre las dimensiones**: `qwen3-embedding` en nan siempre devuelve **4096 dimensiones** (no soporta el parámetro `dimensions` de MRL). El gbrain config se inicializa con `embedding_dimensions: 4096`. pgvector usa index HNSW hasta 2000d; arriba de eso cae a scan exacto (más lento pero correcto — gbrain lo maneja solo vía `chunkEmbeddingIndexSql`).

El mapeo gbrain-tier → nan-model vive en `litellm/config.yaml` (aliases de LiteLLM). El shim reescribe los paths `/v1/messages` (Anthropic) → `/v1/messages` (LiteLLM) y LiteLLM traduce el body Anthropic ↔ OpenAI.

## Comandos comunes

```bash
docker compose exec gbrain gbrain doctor --fast
docker compose exec gbrain gbrain put notas/mi-idea "# Título"
docker compose exec gbrain gbrain embed --all
docker compose exec gbrain gbrain query "qué dijo X sobre Y?"
docker compose exec gbrain gbrain think "resume mi brain"
```

## Exponer a internet

El contenedor expone el puerto 3131 internamente (mapeado a `8080` en el compose). Si lo pones detrás de un reverse proxy externo, define `PUBLIC_URL` para que el OAuth funcione:

```bash
PUBLIC_URL=https://gbrain.midominio.com
```

## Arquitectura

```
                          gbrain CLI
                              │
            ┌─────────────────┼──────────────────┐
            │                 │                  │
      embeddings           chat/expansion       subagent
            │                 │                  │
            │           ANTHROPIC_BASE_URL       │
            │          → localhost:4001           │
            │                 │                  │
            ▼                 ▼                  ▼
    LITELLM_BASE_URL    ┌──────────────────────────┐
    → localhost:4000    │ anthropic-shim (bun)     │  :4001
            │          │ /messages → /v1/messages │
            └─────┬────└──────────────────────────┘
                  │                  │
                  ▼                  ▼
          ┌──────────────────────────────┐
          │ LiteLLM proxy               │  :4000
          │ - openai/gemma4             │
          │ - openai/qwen3.6            │
          │ - openai/qwen3-embedding    │
          │ - claude-opus→deepseek-v4   │
          │ - claude-sonnet→qwen3.6     │
          │ - claude-haiku→gemma4       │
          └──────────────┬───────────────┘
                         ▼
                api.nan.builders
```

Y el storage:

```
   gbrain process
        │
        ├── PGLite (Postgres 17 WASM) ──→ /data/.gbrain/brain.db
        │
        ├── LiteLLM (subprocess) ──→ :4000
        │
        └── anthropic-shim (subprocess) ──→ :4001
```

## Migrar a Supabase/Postgres (si el brain crece)

PGLite está bien hasta ~50K páginas. Si necesitás más:

```bash
gbrain migrate --to supabase
```

Más info: [docs/ENGINES.md](https://github.com/garrytan/gbrain/blob/master/docs/ENGINES.md).

## Licencia

MIT
