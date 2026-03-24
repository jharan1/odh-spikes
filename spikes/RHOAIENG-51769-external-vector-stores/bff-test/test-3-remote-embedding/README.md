# BFF Test 3 — External Vector Store with Remote Embedding Model

Same scenario as test-1-pgvector (pgvector backend, credential injection) but the vector store
uses a **remote** embedding model (`RedHatAI/granite-embedding-english-r2`) served by a vLLM
InferenceService rather than the default inline sentence-transformers model.

This verifies that:

1. A remote embedding model defined in `gen-ai-aa-external-models` with `model_type: embedding`
   can be referenced as the `embedding_model` in `gen-ai-aa-vector-stores`.
2. Including it in the install request with `model_source_type: custom_endpoint` causes the BFF
   to register it in the LSD config alongside the vector store.
3. The full RAG pipeline works end-to-end using the remote embedding model.

## How the embedding model registration flows

```
gen-ai-aa-external-models ConfigMap
  └── provider: granite-embed-provider (remote::openai, base_url: <vLLM endpoint>)
  └── model: RedHatAI/granite-embedding-english-r2 (model_type: embedding, dim: 768)

Install request Models array
  └── { model_name: "RedHatAI/granite-embedding-english-r2", model_source_type: "custom_endpoint" }
      └── BFF reads external models ConfigMap, finds the provider + model
      └── Registers remote::openai provider + embedding model in llama-stack-config

gen-ai-aa-vector-stores ConfigMap
  └── embedding_model: RedHatAI/granite-embedding-english-r2  ← matches the registered model ID
      └── BFF validates embedding model is registered → passes
      └── Vector store wired to use it in llama-stack-config
```

## Cluster State

- Namespace: `proj1` — LSD and embedding InferenceService deployed here
- Namespace: `pgvect` — pgvector2 running here (same as test-1)
- LSD name: `lsd-genai-playground`
- BFF running locally on port `8080` (via `make run` in the `bff/` directory)
- LlamaStack port-forwarded locally on port `8321`

## Prerequisites

- A running OpenShift cluster with ODH / gen-ai dashboard deployed
- `pgvector2` running in the `pgvect` namespace (deployed by `vector-stores-table-test/01-pgvect-pgvector.yaml`)
- BFF changes from RHOAIENG-51773 applied and running
- Bearer token: `TOKEN=$(oc whoami -t)`

## Setup

### Step 1: Deploy the embedding model InferenceService

```bash
kubectl apply -f 01-embedding-inferenceservice.yaml -n proj1
kubectl wait --for=condition=Ready inferenceservice/granite-embedding-r2 -n proj1 --timeout=300s
```

Confirm the `/v1/embeddings` endpoint is reachable (port-forward for a quick check):

```bash
oc port-forward -n proj1 svc/granite-embedding-r2-predictor 8082:80 &
curl -s http://localhost:8082/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model": "RedHatAI/granite-embedding-english-r2", "input": "hello world"}' | jq '.data[0].embedding | length'
# Expected: 768
```

### Step 2: Apply secrets and ConfigMaps to proj1

```bash
kubectl apply -f - <<'EOF'
# Credential secret for pgvector (same as test-1)
apiVersion: v1
kind: Secret
metadata:
  name: pgvector-bff-credentials
  namespace: proj1
type: Opaque
stringData:
  password: "vectorpass2"
---
# Dummy API key for vLLM embedding endpoint (vLLM has no auth by default;
# LlamaStack's remote::openai provider requires a key field to be present)
apiVersion: v1
kind: Secret
metadata:
  name: granite-embed-api-key
  namespace: proj1
type: Opaque
stringData:
  api_key: "fake"
---
# External models ConfigMap — registers the remote embedding model
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-external-models
  namespace: proj1
data:
  config.yaml: |
    providers:
      inference:
        - provider_id: granite-embed-provider
          provider_type: remote::openai
          config:
            base_url: http://granite-embedding-r2-predictor.proj1.svc.cluster.local/v1
            custom_gen_ai:
              api_key:
                secretRef:
                  name: granite-embed-api-key
                  key: api_key

    registered_resources:
      models:
        - provider_id: granite-embed-provider
          model_id: RedHatAI/granite-embedding-english-r2
          model_type: embedding
          metadata:
            display_name: "Granite Embedding English R2 (RedHatAI)"
            embedding_dimension: 768
---
# Vector stores ConfigMap — pgvector backend, references the remote embedding model
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
            custom_gen_ai:
              credentials:
                secretRefs:
                  - name: pgvector-bff-credentials
                    key: password

    registered_resources:
      vector_stores:
        - provider_id: pgvector-bff-provider
          vector_store_id: vs_bff00003-0000-0000-0000-000000000001
          vector_store_name: "BFF Test Knowledge Base (Remote Embedding)"
          embedding_model: RedHatAI/granite-embedding-english-r2
          embedding_dimension: 768
          metadata:
            description: "Test vector store using remote vLLM-hosted granite embedding model"
EOF
```

### Step 3: Port-forward LlamaStack (after install)

```bash
oc port-forward -n proj1 svc/lsd-genai-playground-service 8321:8321 &
```

---

## Test — Install LSD, Upload Context, and Query via RAG

> **Note**: If an LSD already exists in `proj1`, delete it first:
> `oc delete llamastackdistribution lsd-genai-playground -n proj1`

### Step 1: Install the LSD

The install request includes **both** the LLM and the embedding model. The embedding model must
be in the `models` array with `model_source_type: custom_endpoint` so the BFF registers it in
the LSD config, satisfying the vector store's `embedding_model` reference.

```bash
TOKEN=$(oc whoami -t)

curl -s -X POST "http://localhost:8080/api/v1/lsd/install?namespace=proj1" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "models": [
      {
        "model_name": "llama-32-1b-instruct",
        "model_source_type": "namespace"
      },
      {
        "model_name": "RedHatAI/granite-embedding-english-r2",
        "model_source_type": "custom_endpoint"
      }
    ],
    "vector_stores": [
      {
        "vector_store_id": "vs_bff00003-0000-0000-0000-000000000001"
      }
    ]
  }' | jq .
```

**Verify the LSD config:**

```bash
# granite-embed-provider present as remote::openai inference provider
# vector store references RedHatAI/granite-embedding-english-r2
oc get configmap llama-stack-config -n proj1 -o jsonpath='{.data.config\.yaml}' | yq .

# VS_CREDENTIAL_1 → pgvector-bff-credentials/password
oc get deployment lsd-genai-playground -n proj1 \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .
```

### Step 2: Upload context to the vector store

```bash
TOKEN=$(oc whoami -t)

echo "The Acme Widget X200 has a battery life of 72 hours on a single charge. It supports Bluetooth 5.3 and has a water resistance rating of IP68.

The Acme Widget X200 is available in three colours: Midnight Black, Arctic White, and Ocean Blue. The recommended retail price is \$299." > /tmp/product-spec-sheet.txt

curl -s -X POST "http://localhost:8080/api/v1/lsd/vectorstores/files/upload?namespace=proj1" \
  -H "Authorization: Bearer $TOKEN" \
  -F "vector_store_id=vs_bff00003-0000-0000-0000-000000000001" \
  -F "file=@/tmp/product-spec-sheet.txt;type=text/plain" | jq .
```

### Step 3: Query via the responses endpoint

```bash
TOKEN=$(oc whoami -t)

curl -s -X POST "http://localhost:8080/api/v1/lsd/responses?namespace=proj1" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "vllm-inference-1/llama-32-1b-instruct",
    "input": "What is the battery life of the Acme Widget X200?",
    "vector_store_ids": ["vs_bff00003-0000-0000-0000-000000000001"]
  }' | jq .
```

---

## Lessons Learned

*(To be filled after test run)*
