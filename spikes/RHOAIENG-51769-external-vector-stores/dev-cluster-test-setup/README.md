# Dev Cluster Test Setup — External Vector Store with Remote Embedding

Sets up an external pgvector-backed vector store with a remote embedding model on a personal
dev cluster.

## Architecture

```
pgvect namespace
  └── pgvector2 (PostgreSQL 16 + pgvector v0.6.2)
  └── NetworkPolicy: allow-from-test (TCP 5432 from test namespace)

test namespace
  ├── granite-embedding-r2 (InferenceService) — remote::passthrough embedding model
  ├── llama-32-1b-instruct (InferenceService) — LLM for the playground (pre-existing)
  ├── Secret: pgvector-external-credentials
  ├── ConfigMap: gen-ai-aa-custom-model-endpoints
  └── ConfigMap: gen-ai-aa-vector-stores
```

**Vector store:** `vs_bff00003-0000-0000-0000-000000000001` ("Weather Knowledge Base (Remote Embedding)")
- Provider: pgvector2 in `pgvect` namespace (COSINE distance)
- Embedding model: `RedHatAI/granite-embedding-english-r2` (768 dim) via `granite-embedding-r2` InferenceService

## Prerequisites

- Logged in as cluster admin: `oc whoami` should return `admin`
- An LLM InferenceService already deployed in the `test` namespace (e.g. `llama-32-1b-instruct`)

## Apply Order

### Step 1 — pgvector (pgvect namespace)

```bash
oc new-project pgvect
oc apply -f 01-pgvector.yaml
```

Wait for the pod to be Ready, then install the pgvector extension:

```bash
oc rollout status deployment/pgvector2 -n pgvect --timeout=120s
oc exec -n pgvect deployment/pgvector2 -- \
  psql -U postgres -d vectordb -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

Verify:

```bash
oc exec -n pgvect deployment/pgvector2 -- \
  psql -U vectoruser -d vectordb -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';"
# Expected: vector | 0.6.2
```

### Step 2 — Secrets and ConfigMaps (test namespace)

```bash
oc apply -f 02-secrets-and-configmaps.yaml
```

Creates:
- `Secret/pgvector-external-credentials` — pgvector password
- `ConfigMap/gen-ai-aa-custom-model-endpoints` — registers granite-embed-provider (remote::passthrough)
- `ConfigMap/gen-ai-aa-vector-stores` — registers the pgvector-backed Weather Knowledge Base

### Step 3 — Granite Embedding InferenceService (test namespace)

```bash
oc apply -f 03-granite-embedding-inferenceservice.yaml
```

Wait for the InferenceService to be Ready (~2-3 minutes for modelcar pull + vLLM CPU startup):

```bash
oc wait --for=condition=Ready inferenceservice/granite-embedding-r2 -n test --timeout=300s
```

### Step 4 — Install the Playground via UI

1. Navigate to **AI Services** > **Gen AI**, select namespace `test`
2. Click **Configure Playground**
3. The "Weather Knowledge Base (Remote Embedding)" vector store should appear
4. Select the vector store and the `llama-32-1b-instruct` model, then install
5. Wait for the LSD pod to be Ready

```bash
oc get pod -n test -w | grep lsd
```

### Step 5 — Ingest Weather Data (Direct pgvector Insert)

LlamaStack's file ingestion API (`POST /v1/vector_stores/{id}/files`) doesn't work with
`remote::passthrough` embedding providers — the async background task loses the request header
context. Instead, pre-compute the embedding by calling the granite InferenceService directly,
then insert the row into pgvector.

**Weather content** (`weather.txt`):
```
Today's weather is sunny with a high of 25°C and a low of 15°C. There is a 10% chance of rain.
```

```bash
NAMESPACE=test
PG_POD=$(oc get pods -n pgvect -o name | head -1 | sed 's/pod\///')
EMBED_POD=$(oc get pod -n $NAMESPACE -l serving.kserve.io/inferenceservice=granite-embedding-r2 \
  -o jsonpath='{.items[0].metadata.name}')

# 1. Compute embedding via granite-embedding-r2 InferenceService (in-cluster, no API key needed)
EMBEDDING=$(oc exec -n $NAMESPACE $EMBED_POD -c kserve-container -- \
  curl -s -X POST http://localhost:8080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model": "RedHatAI/granite-embedding-english-r2", "input": ["Today'\''s weather is sunny with a high of 25C and a low of 15C. There is a 10% chance of rain."]}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('['+','.join(map(str,d['data'][0]['embedding']))+']')")

# 2. Insert directly into pgvector with the LlamaStack EmbeddedChunk document schema
python3 ingest_weather.py "$EMBEDDING" "$PG_POD"
```

### Step 6 — Verify Ingestion

```bash
PG_POD=$(oc get pods -n pgvect -o name | head -1 | sed 's/pod\///')
oc exec -n pgvect $PG_POD -- psql -U vectoruser -d vectordb \
  -c "SELECT COUNT(*) FROM vs_vs_bff00003_0000_0000_0000_000000000001;"
# Expected: count = 1
```

### Step 7 — Test in the Chat Playground

Ask: **"What is the weather today?"**

The model should respond using the ingested weather context via RAG retrieval.

## Status Checks

```bash
# pgvector pod and extension
oc get pod -n pgvect
oc exec -n pgvect deployment/pgvector2 -- psql -U vectoruser -d vectordb -c "\dt"

# InferenceServices
oc get inferenceservice -n test

# LSD playground pod
oc get pod -n test | grep lsd

# LSD logs (check for startup errors)
oc logs -n test -l app.kubernetes.io/name=lsd-genai-playground --tail=30
```

## Teardown

```bash
# Delete the playground
oc delete ogxserver lsd-genai-playground -n test

# Delete embedding InferenceService
oc delete inferenceservice granite-embedding-r2 -n test
oc delete servingruntime granite-embedding-r2 -n test

# Delete ConfigMaps and Secret
oc delete configmap gen-ai-aa-vector-stores -n test
oc delete configmap gen-ai-aa-custom-model-endpoints -n test
oc delete secret pgvector-external-credentials -n test

# Delete pgvector namespace
oc delete project pgvect
```

## Pitfalls

### Secret name must NOT be `genai-pgvector-credentials`

The BFF's pgvector auto-provisioner uses `genai-pgvector-credentials` as its managed secret name.
During playground install, the following sequence occurs:

1. Auto-provisioner runs first and tries to `Create` a secret named `genai-pgvector-credentials`
2. Vector store ConfigMap validation runs after and checks that the `secretRefs` secret exists

If you pre-create a secret named `genai-pgvector-credentials`, the provisioner fails with
`"already exists"`. If you don't create it, the ConfigMap validation fails with `"not found"`.

**Solution:** Use a different secret name (e.g. `pgvector-external-credentials`) in the
vector store ConfigMap's `secretRefs` to avoid colliding with the auto-provisioner.

### pgvector must be in the same namespace OR have a NetworkPolicy

If pgvector runs in a different namespace, you must create a NetworkPolicy in that namespace
allowing ingress on port 5432 from the LSD pod's namespace. Without it, the LSD pod will
crash-loop with `RuntimeError: Could not connect to PGVector database server` (connection timeout).

### Auto-provisioned pgvector coexists with external

The BFF auto-provisioner will create its own `genai-pgvector` deployment in the `test` namespace
regardless of whether an external pgvector is configured via ConfigMap. These are independent —
the auto-provisioned one is for built-in vector stores, the ConfigMap-configured one is for
external vector stores. Both can run side by side.

If the auto-provisioner detects an existing `genai-pgvector` deployment, it validates that all
companion resources (Secret, ConfigMap `genai-pgvector-init`, PVC, Service, NetworkPolicy) exist
with the `gen-ai.opendatahub.io/pgvector: "true"` label. Missing any of these causes an error.
Don't manually create partial pgvector resources with the `genai-pgvector` name.
