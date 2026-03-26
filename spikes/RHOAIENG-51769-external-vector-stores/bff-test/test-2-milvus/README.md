# BFF Test 2 — Register External Vector Stores via LSD Install (Milvus)

Same scenario as test-1-pgvector but using a remote milvus instance with auth enabled.
Verifies that:

1. The BFF correctly maps `custom_gen_ai.credentials.secretRefs[key: token]` for a
   `remote::milvus` provider, injecting it as `${env.VS_CREDENTIAL_N:=}` in the `token` field.
2. The unauthenticated milvus case is also handled — the BFF always writes `token: ${env.VS_CREDENTIAL_N:=}`
   (resolves to empty string if the env var is unset), because LlamaStack's milvus provider
   requires the `token` field to be present regardless of auth configuration.
3. The full RAG pipeline (install → upload → query) works end-to-end against milvus.

See `configmap-snapshots.md` for the ConfigMap content captured after a successful run.

## Cluster State

- Namespace: `proj1` — LSD is installed here
- Namespace: `milvus` — milvus running here (same instance used in the initial-spike tests)
- LSD name: `lsd-genai-playground`
- BFF running locally on port `8080` (via `make run` in the `bff/` directory)
- LlamaStack port-forwarded locally on port `8321`

## Prerequisites

- A running OpenShift cluster with ODH / gen-ai dashboard deployed
- An existing `proj1` namespace
- Milvus running in the `milvus` namespace with authorization enabled
  (used in the initial-spike tests; the instance at `vectordb-milvus.milvus.svc.cluster.local:19530`)
- BFF changes from RHOAIENG-51773 applied and running
- Bearer token: `TOKEN=$(oc whoami -t)`

## Setup

```bash
# 1. Confirm milvus is running in the milvus namespace
oc get pods -n milvus

# 2. Port-forward LlamaStack
oc port-forward -n proj1 svc/lsd-genai-playground 8321:8321 &

# 3. Apply the credential secret and vector stores ConfigMap to proj1
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: milvus-bff-credentials
  namespace: proj1
type: Opaque
stringData:
  token: "root:Milvus"
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
        - provider_id: milvus-bff-provider
          provider_type: remote::milvus
          config:
            uri: http://vectordb-milvus.milvus.svc.cluster.local:19530
            persistence:
              backend: kv_default
              namespace: vector_io::milvus-bff-provider
            custom_gen_ai:
              credentials:
                secretRefs:
                  - name: milvus-bff-credentials
                    key: token

    registered_resources:
      vector_stores:
        - provider_id: milvus-bff-provider
          vector_store_id: vs_bff00002-0000-0000-0000-000000000001
          vector_store_name: "BFF Test Knowledge Base (Milvus)"
          embedding_model: ibm-granite/granite-embedding-125m-english
          embedding_dimension: 768
          metadata:
            description: "Test vector store for BFF install endpoint testing using milvus"
EOF
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
        "vector_store_id": "vs_bff00002-0000-0000-0000-000000000001"
      }
    ]
  }' | jq .
```

**Verify the LSD config** (see `configmap-snapshots.md` for expected output):

```bash
# milvus-bff-provider present, custom_gen_ai absent, token uses env var syntax
oc get configmap llama-stack-config -n proj1 -o jsonpath='{.data.config\.yaml}' | yq .

# VS_CREDENTIAL_1 injected as SecretKeyRef pointing to milvus-bff-credentials / token
oc get deployment lsd-genai-playground -n proj1 \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .

# Expected env var entry:
# {
#   "name": "VS_CREDENTIAL_1",
#   "valueFrom": {
#     "secretKeyRef": {
#       "name": "milvus-bff-credentials",
#       "key": "token"
#     }
#   }
# }
```

### Step 2: Upload context to the vector store

```bash
TOKEN=$(oc whoami -t)

echo "The Acme Widget X200 has a battery life of 72 hours on a single charge. It supports Bluetooth 5.3 and has a water resistance rating of IP68.

The Acme Widget X200 is available in three colours: Midnight Black, Arctic White, and Ocean Blue. The recommended retail price is \$299." > /tmp/product-spec-sheet.txt

curl -s -X POST "http://localhost:8080/api/v1/lsd/vectorstores/files/upload?namespace=proj1" \
  -H "Authorization: Bearer $TOKEN" \
  -F "vector_store_id=vs_bff00002-0000-0000-0000-000000000001" \
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
    "vector_store_ids": ["vs_bff00002-0000-0000-0000-000000000001"]
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
        "results": [{ "score": ..., "text": "The Acme Widget X200 has a battery life of 72 hours..." }]
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

*(To be filled after test run)*
