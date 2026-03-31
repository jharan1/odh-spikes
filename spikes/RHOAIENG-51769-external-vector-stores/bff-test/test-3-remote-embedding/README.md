# BFF Test 3 — External Vector Store with Remote Embedding Model

Same scenario as test-1-pgvector (pgvector backend, credential injection) but the vector store
uses a **remote** embedding model (`RedHatAI/granite-embedding-english-r2`) served by a vLLM
InferenceService rather than the default inline sentence-transformers model.

This verifies that:

1. A remote embedding model defined in `gen-ai-aa-custom-model-endpoints` with `model_type: embedding`
   can be referenced as the `embedding_model` in `gen-ai-aa-vector-stores`.
2. Installing an LSD from the UI with the embedding model selected causes the BFF to register it
   in the LSD config alongside the vector store.
3. The full RAG pipeline works end-to-end using the remote embedding model.

## How the embedding model registration flows

```
gen-ai-aa-custom-model-endpoints ConfigMap
  └── provider: granite-embed-provider (remote::passthrough, base_url: <vLLM endpoint>)
  └── model: RedHatAI/granite-embedding-english-r2 (model_type: embedding, dim: 768)

LSD install (from UI, user selects the embedding model)
  └── BFF reads custom endpoints ConfigMap, finds the provider + model
  └── Registers remote::passthrough provider + embedding model in llama-stack-config
  └── BFF sets provider_model_id = model_id to ensure LlamaStack identifier lookup works

gen-ai-aa-vector-stores ConfigMap
  └── embedding_model: RedHatAI/granite-embedding-english-r2  ← matches the registered model ID
      └── LlamaStack registers the vector store wired to use the remote embedding
```

## Cluster State

- Namespace: `proj1` — LSD and embedding InferenceService deployed here
- Namespace: `pgvect` — pgvector2 running here
- LSD name: `lsd-genai-playground`
- LSD installed from the Gen AI playground UI (not via BFF API curl)

## Prerequisites

- A running OpenShift cluster with ODH / gen-ai dashboard deployed
- `pgvector2` running in the `pgvect` namespace
- BFF changes from RHOAIENG-51773 applied (specifically commit `55a78938d` for `provider_model_id` fix)
- Feature flags set in `OdhDashboardConfig`:
  ```yaml
  spec:
    dashboardConfig:
      disableExternalVectorStores: false
      aiAssetCustomEndpoints: true
    genAiStudioConfig:
      aiAssetCustomEndpoints:
        externalProviders: true
  ```

## Setup

### Step 1: Deploy the embedding model InferenceService

```bash
kubectl apply -f 01-embedding-inferenceservice.yaml -n proj1
kubectl wait --for=condition=Ready inferenceservice/granite-embedding-r2 -n proj1 --timeout=300s
```

Confirm the `/v1/embeddings` endpoint is reachable (port-forward for a quick check):

```bash
oc port-forward -n proj1 svc/granite-embedding-r2-predictor 18080:80 &
curl -s http://localhost:18080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model": "RedHatAI/granite-embedding-english-r2", "input": ["hello world"]}' | jq '.data[0].embedding | length'
# Expected: 768
```

### Step 2: Apply ConfigMaps to proj1

Apply the custom model endpoints configmap (registers the embedding provider):

```bash
oc apply -f 02-external-models-configmap.yaml -n proj1
```

Apply the vector stores configmap:

```bash
oc apply -f 03-vector-stores-configmap.yaml -n proj1
```

Apply the pgvector credential secret:

```bash
oc create secret generic pgvector-bff-credentials \
  --from-literal=password=vectorpass2 \
  -n proj1
```

> **Note**: No `granite-embed-api-key` secret is needed — the KServe InferenceService has no
> authentication, and `remote::passthrough` does not embed an API key in the provider config.

### Step 3: Install LSD from the UI

Delete any existing LSD, then install from the Gen AI playground UI, selecting:
- `llama-32-3b-instruct` (or any available LLM)
- `RedHatAI/granite-embedding-english-r2` (custom endpoint, for Weather KB)

The BFF generates `llama-stack-config` automatically on install.

**Verify the LSD config has the correct provider type:**

```bash
oc get configmap llama-stack-config -n proj1 -o jsonpath='{.data.config\.yaml}' | grep -A3 granite-embed-provider
# Expected: provider_type: remote::passthrough
```

### Step 4: Ingest test data via direct pgvector insert

> **Why not the file upload API?**
> LlamaStack's `POST /v1/vector_stores/{id}/files` spawns an async background task. The
> `remote::passthrough` provider reads its API key from the `X-LlamaStack-Provider-Data` header at
> call time, but that header (and request context) is gone when the background task runs. This
> affects all `remote::passthrough` embedding providers regardless of auth requirements.

Port-forward to the KServe embedding service, compute the embedding, then insert directly:

```bash
WEATHER_TEXT="Todays weather is sunny with a high of 25C and a low of 15C. There is a 10% chance of rain."

# 1. Port-forward to the KServe embedding service
oc port-forward svc/granite-embedding-r2-predictor 18080:80 -n proj1 &
sleep 3

# 2. Compute embedding
EMBEDDING=$(curl -s http://localhost:18080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"RedHatAI/granite-embedding-english-r2\", \"input\": [\"${WEATHER_TEXT}\"]}" \
  | jq -r '.data[0].embedding | "[" + (map(tostring) | join(",")) + "]"')

CHUNK_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
FILE_ID="file-granite-direct-insert"
NOW=$(date +%s)
TABLE="vs_vs_bff00003_0000_0000_0000_000000000001"
PG_POD=$(oc get pods -n pgvect -o name | head -1 | sed 's/pod\///')

# 3. Insert directly into pgvector
oc exec -n pgvect $PG_POD -- psql -U vectoruser -d vectordb -c \
"INSERT INTO ${TABLE} (id, document, embedding, content_text, tokenized_content)
VALUES (
  '${CHUNK_ID}',
  '{\"content\": \"${WEATHER_TEXT}\", \"chunk_id\": \"${CHUNK_ID}\", \"metadata\": {\"file_id\": \"${FILE_ID}\", \"chunk_id\": \"${CHUNK_ID}\", \"filename\": \"weather.txt\", \"document_id\": \"${FILE_ID}\", \"token_count\": 39, \"chunk_tokenizer\": \"tiktoken:cl100k_base\", \"metadata_token_count\": 20}, \"chunk_metadata\": {\"source\": null, \"chunk_id\": \"${CHUNK_ID}\", \"document_id\": \"${FILE_ID}\", \"chunk_window\": \"0-39\", \"chunk_tokenizer\": \"tiktoken:cl100k_base\", \"created_timestamp\": ${NOW}, \"updated_timestamp\": ${NOW}, \"content_token_count\": 39, \"metadata_token_count\": 20}, \"embedding_model\": \"RedHatAI/granite-embedding-english-r2\", \"embedding_dimension\": 768}'::jsonb,
  '${EMBEDDING}'::vector,
  '${WEATHER_TEXT}',
  to_tsvector('english', '${WEATHER_TEXT}')
);"
```

### Step 5: Verify ingestion

```bash
PG_POD=$(oc get pods -n pgvect -o name | head -1 | sed 's/pod\///')
oc exec -n pgvect $PG_POD -- psql -U vectoruser -d vectordb \
  -c "SELECT COUNT(*) FROM vs_vs_bff00003_0000_0000_0000_000000000001;"
# Expected: 1
```

### Step 6: Verify search via LlamaStack

```bash
oc port-forward svc/lsd-genai-playground-service 18321:8321 -n proj1 &
sleep 3

curl -s -X POST "http://localhost:18321/v1/vector_stores/vs_bff00003-0000-0000-0000-000000000001/search" \
  -H "Content-Type: application/json" \
  -d '{"query": "what is the weather today", "max_num_results": 3}' | jq '.data[].content[].text'
# Expected: "Todays weather is sunny with a high of 25C..."
```

---

## Test question for playground

**Suggested question:** `"What is the weather today?"`

---

## Lessons Learned

### `remote::passthrough` vs `remote::openai` for internal KServe embedding services

Use `remote::passthrough` (not `remote::openai`) for internal KServe InferenceServices used as embedding providers. This is required because:

1. **UI visibility**: `computeEmbeddingModelStatus` (frontend utility) checks the custom endpoints configmap to determine if an embedding model is "available" for selection. The function uses provider type to distinguish embedding providers — `remote::passthrough` is correctly identified, while `remote::openai` is not.

2. **No auth needed**: The KServe InferenceService has no authentication, so `remote::passthrough` (which handles API keys via the request header at runtime) is appropriate. No `api_key` secretRef in the provider config.

3. **Base URL**: For `remote::passthrough`, do **not** append `/v1` to the base URL. LlamaStack's passthrough client constructs the full URL internally.

### `provider_model_id` must be set for custom endpoint embedding models

LlamaStack builds each model's identifier as `f"{provider_id}/{provider_model_id}"`. If `provider_model_id` is empty, the stored identifier mismatches what `register_vector_store` searches for, causing `ModelNotFoundError`.

BFF commit `55a78938d` fixes this by falling back to `model_id` when `provider_model_id` is not set, and registering both as lookup keys. This fix is required — ensure the BFF is running with this commit applied.

### File ingestion is not possible via `remote::passthrough` for async operations

LlamaStack's file ingestion API spawns an async background task. The `remote::passthrough` provider reads its API key (and URL) from the `X-LlamaStack-Provider-Data` request header, but that header is gone by the time the background task runs. This is a fundamental LlamaStack limitation for all `remote::passthrough` providers.

**Workaround**: Pre-compute embeddings externally (port-forward to the KServe service or call the external embedding API directly), then insert rows directly into pgvector with the correct `EmbeddedChunk` document schema.

### Required pgvector document schema (`EmbeddedChunk`)

The `document` JSONB column must include `chunk_metadata` as a top-level field alongside `metadata`. Missing `chunk_metadata` causes a pydantic validation error when LlamaStack deserializes search results, even though the vector similarity search itself succeeds. See the e2e-tests README for the full required schema.
