# Demo Cluster Bootstrap — External Vector Stores E2E

Bootstraps a complete external vector store demo on the **crimson-rhoai** cluster (`api.crimson-rhoai.h6fk.p3.openshiftapps.com`).

## Architecture

```
pgvect namespace
  └── pgvector2 (PostgreSQL 16 + pgvector extension)
        ↑ used by vector store vs_bff00003

demo-vector-stores-e2e namespace
  ├── granite-embedding-r2 (InferenceService) — remote::passthrough embedding model
  ├── llama-32-3b-instruct (InferenceService) — LLM for the playground
  ├── Secret: pgvector-bff-credentials
  ├── ConfigMap: gen-ai-aa-custom-model-endpoints
  └── ConfigMap: gen-ai-aa-vector-stores
```

**Vector store:** `vs_bff00003-0000-0000-0000-000000000001` ("Weather Knowledge Base (Remote Embedding)")
- Provider: pgvector2 in `pgvect` namespace (COSINE distance)
- Embedding model: `RedHatAI/granite-embedding-english-r2` (768 dim) via `granite-embedding-r2` InferenceService

## Apply Order

### Prerequisites

Logged in as cluster admin:
```bash
oc whoami   # htpasswd-cluster-admin-user
```

### Step 1 — pgvector (pgvect namespace)

Already running on the cluster. To set up from scratch:
```bash
oc new-project pgvect
oc apply -f 01-pgvector.yaml
# Wait for pod to be Ready, then install the extension:
oc exec -n pgvect deployment/pgvector2 -- psql -U postgres -d vectordb -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

Verify:
```bash
oc exec -n pgvect deployment/pgvector2 -- psql -U vectoruser -d vectordb -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';"
# Expected: vector | 0.6.2
```

### Step 2 — Secrets and ConfigMaps

```bash
oc new-project demo-vector-stores-e2e
oc apply -f 02-secrets-and-configmaps.yaml
```

Creates:
- `Secret/pgvector-bff-credentials` — pgvector password for the BFF
- `ConfigMap/gen-ai-aa-custom-model-endpoints` — registers granite-embed-provider (remote::passthrough)
- `ConfigMap/gen-ai-aa-vector-stores` — registers the pgvector-backed weather knowledge base

### Step 3 — Granite Embedding InferenceService

```bash
oc apply -f 03-granite-embedding-inferenceservice.yaml
```

Creates `ServingRuntime` + `InferenceService` for `granite-embedding-r2` using vLLM CPU with `--task=embed`.
- Model: `oci://quay.io/redhat-ai-services/modelcar-catalog:granite-embedding-english-r2`
- Served as: `RedHatAI/granite-embedding-english-r2`
- Endpoint: `http://granite-embedding-r2-predictor.demo-vector-stores-e2e.svc.cluster.local/v1/embeddings`

### Step 4 — Llama 3B InferenceService

```bash
oc apply -f 04-llama-3b-inferenceservice.yaml
```

Creates `ServingRuntime` + `InferenceService` for `llama-32-3b-instruct`.
- Model: `oci://quay.io/redhat-ai-services/modelcar-catalog:llama-3.2-3b-instruct`
- Resources: 4 CPU / 16Gi RAM (increased from default — 3B model requires ~6Gi+ KV cache overhead)

## Status Checks

```bash
# Watch pods come up
oc get pod -n demo-vector-stores-e2e -w

# Check InferenceService readiness
oc get inferenceservice -n demo-vector-stores-e2e

# Verify embedding endpoint
oc exec -n demo-vector-stores-e2e deployment/granite-embedding-r2-predictor -- \
  curl -s http://localhost:8080/v1/models | jq .

# Verify pgvector connectivity from cluster
oc exec -n pgvect deployment/pgvector2 -- \
  psql -U vectoruser -d vectordb -c "\dt"
```

## Step 5 — Install the LSD Playground via UI

Once both InferenceServices are Ready, go to the RHOAI dashboard:

1. Navigate to **AI Services** → **Gen AI**, select namespace `demo-vector-stores-e2e`
2. Click **Configure Playground**
3. The "Weather Knowledge Base (Remote Embedding)" vector store should appear (from `gen-ai-aa-vector-stores` ConfigMap)
4. Select the vector store and the `llama-32-3b-instruct` model, then install
5. Wait for the LSD pod to be Ready — it will create the pgvector tables on startup

```bash
# Watch LSD pod come up
oc get pod -n demo-vector-stores-e2e -w
```

## Step 6 — Ingest Weather Data (Direct pgvector Insert)

### Why direct insert?

LlamaStack's file ingestion API (`POST /v1/vector_stores/{id}/files`) spawns an async background
task for chunking and embedding. The `remote::passthrough` embedding provider reads its API key
exclusively from the `X-LlamaStack-Provider-Data` request header — which is gone by the time the
background task runs. This causes:

```
ValueError: Pass API Key for the passthrough endpoint in the header X-LlamaStack-Provider-Data
```

**Workaround:** pre-compute the embedding by calling the granite embedding InferenceService
directly (no API key needed — it's in-cluster), then insert the row directly into pgvector with
the exact document schema LlamaStack expects.

### Weather content

File: `weather.txt`
```
Today's weather is sunny with a high of 25°C and a low of 15°C. There is a 10% chance of rain.
```

**Suggested test question:** `"What is the weather today?"`

### Ingest script

```bash
WEATHER_TEXT="Today's weather is sunny with a high of 25C and a low of 15C. There is a 10% chance of rain."
VS_TABLE="vs_vs_bff00003_0000_0000_0000_000000000001"
PG_POD=$(oc get pods -n pgvect -o name | head -1 | sed 's/pod\///')
EMBED_POD=$(oc get pod -n demo-vector-stores-e2e -l serving.kserve.io/inferenceservice=granite-embedding-r2 -o jsonpath='{.items[0].metadata.name}')

# 1. Compute embedding via granite-embedding-r2 InferenceService (in-cluster, no API key needed)
EMBEDDING=$(oc exec -n demo-vector-stores-e2e $EMBED_POD -c kserve-container -- \
  curl -s -X POST http://localhost:8080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"RedHatAI/granite-embedding-english-r2\", \"input\": [\"${WEATHER_TEXT}\"]}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('['+','.join(map(str,d['data'][0]['embedding']))+']')")

CHUNK_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
FILE_ID="file-weather-direct-insert"
NOW=$(python3 -c "import time; print(int(time.time()))")

# 2. Insert directly into pgvector with the LlamaStack EmbeddedChunk document schema
oc exec -n pgvect $PG_POD -- psql -U vectoruser -d vectordb -c \
"INSERT INTO ${VS_TABLE} (id, document, embedding, content_text, tokenized_content)
VALUES (
  '${CHUNK_ID}',
  '{\"content\": \"${WEATHER_TEXT}\", \"chunk_id\": \"${CHUNK_ID}\", \"metadata\": {\"file_id\": \"${FILE_ID}\", \"chunk_id\": \"${CHUNK_ID}\", \"filename\": \"weather.txt\", \"document_id\": \"${FILE_ID}\", \"token_count\": 20, \"chunk_tokenizer\": \"tiktoken:cl100k_base\", \"metadata_token_count\": 10}, \"chunk_metadata\": {\"source\": null, \"chunk_id\": \"${CHUNK_ID}\", \"document_id\": \"${FILE_ID}\", \"chunk_window\": \"0-20\", \"chunk_tokenizer\": \"tiktoken:cl100k_base\", \"created_timestamp\": ${NOW}, \"updated_timestamp\": ${NOW}, \"content_token_count\": 20, \"metadata_token_count\": 10}, \"embedding_model\": \"RedHatAI/granite-embedding-english-r2\", \"embedding_dimension\": 768}'::jsonb,
  '${EMBEDDING}'::vector,
  '${WEATHER_TEXT}',
  to_tsvector('english', '${WEATHER_TEXT}')
);"
```

### Verify ingestion

```bash
PG_POD=$(oc get pods -n pgvect -o name | head -1 | sed 's/pod\///')
oc exec -n pgvect $PG_POD -- psql -U vectoruser -d vectordb \
  -c "SELECT COUNT(*) FROM vs_vs_bff00003_0000_0000_0000_000000000001;"
# Expected: count = 1
```

## Step 7 — Test in the Chat Playground UI

Once data is ingested:

1. Open the Chat Playground in namespace `demo-vector-stores-e2e`
2. Ask: **"What is the weather today?"**
3. The model should respond using the ingested weather context

## Cluster Notes

- **Cluster:** crimson-rhoai (`api.crimson-rhoai.h6fk.p3.openshiftapps.com`)
- **pgvect namespace:** pre-existing on the cluster (pgvector2 deployed ~7h before demo-vector-stores-e2e)
- **pgvector extension:** v0.6.2, already installed in the `vectordb` database
