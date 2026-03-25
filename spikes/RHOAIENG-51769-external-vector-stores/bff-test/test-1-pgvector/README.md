# BFF Test — Register External Vector Stores via LSD Install

This folder tests the BFF changes for registering external vector stores when creating a
LlamaStack playground (LSD install endpoint). It verifies that:

1. The BFF reads the `gen-ai-aa-vector-stores` ConfigMap, resolves the provider and credential
   secret, and produces a valid LSD with the vector store registered and the credential injected
   as an env var.
2. The installed LSD can answer questions using context uploaded to the vector store (RAG).

See `configmap-snapshots.md` for the full content of both ConfigMaps used in this test.

## Cluster State

- Namespace: `proj1` — LSD is installed here
- Namespace: `pgvect` — pgvector2 running here from the vector-stores-table-test setup (cross-namespace provider scenario)
- LSD name: `lsd-genai-playground`
- BFF running locally on port `8080` (via `make run` in the `bff/` directory)
- LlamaStack port-forwarded locally on port `8321`

## Prerequisites

- A running OpenShift cluster with ODH / gen-ai dashboard deployed
- An existing `proj1` namespace
- `pgvector2` running in the `pgvect` namespace with the vector extension enabled
  (deployed by `vector-stores-table-test/01-pgvect-pgvector.yaml`)
- BFF changes from RHOAIENG-51773 applied and running
- Bearer token: `TOKEN=$(oc whoami -t)`

## Setup

```bash
# 1. Confirm pgvector2 is running in pgvect and the vector extension is enabled
oc get pods -n pgvect
oc exec -n pgvect deployment/pgvector2 -- \
  psql -U postgres -d vectordb -c "CREATE EXTENSION IF NOT EXISTS vector;"

# 2. Apply the credential secret and vector stores ConfigMap to proj1
#    (content in configmap-snapshots.md, section 1)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: pgvector-bff-credentials
  namespace: proj1
type: Opaque
stringData:
  password: "vectorpass2"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-vector-stores
  namespace: proj1
data:
  config.yaml: |
    providers:
      vector_io:
        - provider_id: pgvector-bff-provider
          provider_type: remote::pgvector
          config:
            host: pgvector2.pgvect.svc.cluster.local
            port: 5432
            db: vectordb
            user: vectoruser
            distance_metric: COSINE
            persistence:
              backend: kv_default
              namespace: vector_io::pgvector-bff-provider
            custom_gen_ai:
              credentials:
                secretRefs:
                  - name: pgvector-bff-credentials
                    key: password

    registered_resources:
      vector_stores:
        - provider_id: pgvector-bff-provider
          vector_store_id: vs_bff00001-0000-0000-0000-000000000001
          vector_store_name: "BFF Test Knowledge Base"
          embedding_model: ibm-granite/granite-embedding-125m-english
          embedding_dimension: 768
          metadata:
            description: "Test vector store for BFF install endpoint testing using the default embedding model"
EOF

# 3. Port-forward LlamaStack
oc port-forward -n proj1 svc/lsd-genai-playground 8321:8321 &
```

---

## Test — Install LSD, Upload Context, and Query via RAG

Find the model ID available in your cluster:

```bash
curl -s http://localhost:8321/v1/models | jq '[.data[] | .id]'
```

> **Note**: If an LSD already exists in `proj1`, delete it first:
> `oc delete llamastackdistribution lsd-genai-playground -n proj1`

### Step 1: Install the LSD with the vector store

```bash
TOKEN=$(oc whoami -t)

curl -s -X POST "http://localhost:8080/api/v1/lsd/install?namespace=proj1" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "models": [
      {
        "model_name": "<your-llm-model>",
        "model_source_type": "namespace"
      }
    ],
    "vector_stores": [
      {
        "vector_store_id": "vs_bff00001-0000-0000-0000-000000000001"
      }
    ]
  }' | jq .
```

**Verify the LSD config** (see `configmap-snapshots.md` section 2 for expected output):

```bash
# pgvector provider present, custom_gen_ai absent, password uses env var syntax
oc get configmap llama-stack-config -n proj1 -o jsonpath='{.data.config\.yaml}' | yq .

# VS_CREDENTIAL_PGVECTOR_BFF_PROVIDER_1 injected as SecretKeyRef
oc get deployment lsd-genai-playground -n proj1 \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .
```

### Step 2: Upload context to the vector store

```bash
TOKEN=$(oc whoami -t)

# Create a test document
echo "The Acme Widget X200 has a battery life of 72 hours on a single charge. It supports Bluetooth 5.3 and has a water resistance rating of IP68.

The Acme Widget X200 is available in three colours: Midnight Black, Arctic White, and Ocean Blue. The recommended retail price is \$299." > /tmp/product-spec-sheet.txt

curl -s -X POST "http://localhost:8080/api/v1/lsd/vectorstores/files/upload?namespace=proj1" \
  -H "Authorization: Bearer $TOKEN" \
  -F "vector_store_id=vs_bff00001-0000-0000-0000-000000000001" \
  -F "file=@/tmp/product-spec-sheet.txt;type=text/plain" | jq .
```

### Step 3: Query via the responses endpoint

```bash
TOKEN=$(oc whoami -t)

curl -s -X POST "http://localhost:8080/api/v1/lsd/responses?namespace=proj1" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<your-llm-model>",
    "input": "What is the battery life of the Acme Widget X200?",
    "vector_store_ids": ["vs_bff00001-0000-0000-0000-000000000001"]
  }' | jq .
```

**Expected response** — a `file_search_call` block showing the retrieved chunk, followed by the model's answer:

```json
{
  "data": {
    "output": [
      {
        "type": "file_search_call",
        "queries": ["Acme Widget X200 battery life"],
        "results": [{ "score": 23.5, "text": "The Acme Widget X200 has a battery life of 72 hours..." }]
      },
      {
        "type": "message",
        "content": [{ "type": "output_text", "text": "The battery life of the Acme Widget X200 is 72 hours on a single charge." }]
      }
    ]
  }
}
```

---

## Lessons Learned

- **pgvector requires `persistence` section**: The LlamaStack pgvector provider config must
  include a `persistence` block or the LSD pod will crash. Same is true for milvus (from initial-spike lessons learned).
- **Model ID must match LlamaStack's registry**: Use `curl http://localhost:8321/v1/models | jq '[.data[] | .id]'`
  to find the exact ID. For a vLLM endpoint named `llama-32-1b-instruct` registered under provider
  `vllm-inference-1`, the ID is `vllm-inference-1/llama-32-1b-instruct`.
- **`model_source_type` for cluster vLLM**: Use `"namespace"`, not `"external_endpoint"`.
- **BFF runs on port 8080** (not 4000 — that is the main dashboard backend).
