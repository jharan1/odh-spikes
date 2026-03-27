# Local Demo — External Vector Stores

End-to-end demo showing external vector stores in the Gen AI playground, using pgvector
as the vector database and sentence-transformers (inline) or Mistral (remote) for embeddings.

## Prerequisites

- OpenShift cluster with RHOAI / ODH installed
- pgvector running in a separate namespace (this demo uses `pgvect`)
- `oc` CLI logged in to the cluster
- Gen AI BFF running locally (`make run` from `packages/gen-ai/bff`)

## Cluster Resources

### Namespace

All resources below are created in namespace `proj1`.

### Required Secrets

Create these before applying the ConfigMaps:

```bash
# pgvector DB password
oc create secret generic pgvector-bff-credentials -n proj1 \
  --from-literal=password=<your-pgvector-password>

# Anthropic API key (for Claude Haiku)
oc create secret generic endpoint-api-key-1 -n proj1 \
  --from-literal=api_key=<your-anthropic-api-key>

# Mistral API key (for mistral-embed)
oc create secret generic mistral-api-key -n proj1 \
  --from-literal=api_key=<your-mistral-api-key>
```

### Apply ConfigMaps

```bash
oc apply -f gen-ai-aa-custom-model-endpoints.yaml
oc apply -f gen-ai-aa-vector-stores.yaml
```

**`gen-ai-aa-custom-model-endpoints`** — defines AI Asset endpoint models:
- `claude-haiku-4-5-20251001` — LLM via Anthropic API (OpenAI-compatible)
- `mistral-embed` — embedding model via Mistral API (OpenAI-compatible)

**`gen-ai-aa-vector-stores`** — defines available vector stores:
- `vs_bff00001` — **Veldrix Z9 Product Knowledge Base** (sentence-transformers, 768 dims)
- `vs_bff00003` — Weather Knowledge Base (requires `granite-embedding-r2` InferenceService)
- `vs_bff00004` — Mistral Knowledge Base (requires Mistral API key)

## Install the Playground (LSD)

Call the BFF install endpoint to create a LlamaStackDistribution with Claude Haiku and
the Veldrix vector store:

```bash
TOKEN=$(oc whoami -t)
curl -X POST "http://localhost:8080/api/v1/lsd/install?namespace=proj1" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "models": [
      {"model_name": "claude-haiku-4-5-20251001", "model_source_type": "custom_endpoint"}
    ],
    "vector_stores": [
      {"vector_store_id": "vs_bff00001-0000-0000-0000-000000000001"}
    ]
  }'
```

Wait for the LSD pod to be ready:

```bash
oc wait pod -l app=lsd-genai-playground -n proj1 --for=condition=Ready --timeout=120s
```

## Index Content into the Vector Store

The BFF will port-forward to the LSD at `localhost:8321`. Upload and attach the content file:

```bash
# Upload the file
FILE_ID=$(curl -s -X POST "http://localhost:8321/v1/files" \
  -F "file=@content/veldrix-z9.txt;type=text/plain" \
  -F "purpose=assistants" | jq -r '.id')
echo "Uploaded file: $FILE_ID"

# Attach to the vector store (sentence-transformers runs inline — no API key needed)
curl -s -X POST "http://localhost:8321/v1/vector_stores/vs_bff00001-0000-0000-0000-000000000001/files" \
  -H "Content-Type: application/json" \
  -d "{\"file_id\": \"$FILE_ID\"}" | jq .
```

Verify `status: "completed"` and `last_error: null` in the response.

## Test in the Playground

1. Open the Gen AI playground in the dashboard UI
2. Select **Claude Haiku** as the model
3. Add **Veldrix Z9 Product Knowledge Base** as the vector store
4. Ask: _"How much does the Veldrix Z9 cost?"_
5. Expected answer: `$999` with display specs — confirming RAG is working

## Embedding Model Notes

| Vector Store | Embedding Model | Type | Notes |
|---|---|---|---|
| Veldrix Z9 Product KB | `ibm-granite/granite-embedding-125m-english` | Inline (sentence-transformers) | No API key needed, runs inside LSD |
| Weather KB (Remote) | `RedHatAI/granite-embedding-english-r2` | InferenceService | Requires `granite-embedding-r2` ISVC running in namespace |
| Mistral KB | `mistral-embed` | Remote (Mistral API) | Requires Mistral API key; note: do NOT set `embedding_dimension` in LlamaStack config — Mistral rejects the `dimensions` param |

## Key Learnings

- The `gen-ai-aa-vector-stores` ConfigMap drives what appears in the **Vector Stores** tab in AI Assets
- A vector store row is **enabled** (not greyed out) when its embedding model exists in either:
  - The running LSD's registered models, OR
  - The `gen-ai-aa-custom-model-endpoints` ConfigMap
- The LSD must be **deleted and reinstalled** to pick up vector store name changes — the name
  is persisted in LlamaStack's SQLite DB and is not re-read from the ConfigMap on restart
- `mistral-embed` uses `remote::openai` provider type but does not support the `dimensions`
  parameter — omit `embedding_dimension` from the LlamaStack config for Mistral models
