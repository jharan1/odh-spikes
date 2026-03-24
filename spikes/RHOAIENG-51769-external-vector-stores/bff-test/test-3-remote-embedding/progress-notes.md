# Test-3 Progress Notes

## Status: IN PROGRESS — blocked on ModelNotFoundError during vector store registration

---

## What works so far

- `granite-embedding-r2-predictor` pod is **2/2 Running** in `proj1`
- `/v1/embeddings` returns correct 768-dim vectors (confirmed via curl)
- BFF install request returns **200 OK**
- `llama-stack-config` ConfigMap is generated correctly
- `register_model` for the remote embedding model **succeeds** (using `rhoai-v3.4-ea2-latest` image)

---

## Current blocker

LSD pod crashes at startup:

```
ModelNotFoundError: Model 'RedHatAI/granite-embedding-english-r2' not found
  File "vector_stores.py", line 85, in register_vector_store
    model = await lookup_model(self, embedding_model)
  File "common.py", line 261, in lookup_model
    raise ModelNotFoundError(model_id)
```

### Root cause hypothesis

LlamaStack builds a model's internal identifier as `f"{provider_id}/{provider_model_id}"` (from `models.py`).
Our model entry has `provider_model_id` empty (not set), which likely causes the stored identifier to
mismatch what `lookup_model("RedHatAI/granite-embedding-english-r2")` searches for.

Compare with the working sentence-transformers model:
- `model_id`: `sentence-transformers/ibm-granite/granite-embedding-125m-english`
- `provider_model_id`: `ibm-granite/granite-embedding-125m-english`  ← explicitly set
- identifier: `sentence-transformers/ibm-granite/granite-embedding-125m-english`

Our granite embedding model:
- `model_id`: `RedHatAI/granite-embedding-english-r2`
- `provider_model_id`: *(empty — not set by `NewModel`)*

### Next step to try

Set `provider_model_id = model_id` for custom endpoint embedding models in the BFF's
`AddCustomEndpointProviderAndModel` (use `NewEmbeddingModel` or set `ProviderModelID` explicitly).
The vector store's `embedding_model: RedHatAI/granite-embedding-english-r2` may also need to match
the full identifier — needs investigation.

---

## LlamaStack image

- **Working image**: `quay.io/opendatahub/llama-stack:rhoai-v3.4-ea2-latest`
  - Has PR #5014 (merged March 6 2026): `model_validation` defaults to `false`, so `register_model`
    skips the `/v1/models` availability check → no api_key needed in provider config
- **Old image** (`quay.io/opendatahub/llama-stack:latest`): model_validation always runs →
  fails without `api_key` in the `remote::openai` provider config

Set in `/Users/jharan/code/odh-dashboard/packages/gen-ai/.env.local`:
```
DISTRIBUTION_NAME=quay.io/opendatahub/llama-stack:rhoai-v3.4-ea2-latest
```

---

## LSD spec (as created by BFF)

```yaml
spec:
  network:
    allowedFrom:
      namespaces:
      - proj1
    exposeRoute: false
  replicas: 1
  server:
    containerSpec:
      command:
      - /bin/sh
      - -c
      - llama stack run /etc/llama-stack/config.yaml
      env:
      - name: VLLM_TLS_VERIFY
        value: "false"
      - name: MILVUS_DB_PATH
        value: ~/.llama/milvus.db
      - name: FMS_ORCHESTRATOR_URL
        value: http://localhost
      - name: VLLM_MAX_TOKENS
        value: "4096"
      - name: VLLM_API_TOKEN_1
        value: fake
      - name: VLLM_API_TOKEN_2
        value: fake
      - name: VS_CREDENTIAL_1
        valueFrom:
          secretKeyRef:
            key: password
            name: pgvector-bff-credentials
      - name: LLAMA_STACK_CONFIG_DIR
        value: /opt/app-root/src/.llama/distributions/rh/
      name: llama-stack
      port: 8321
      resources:
        limits:
          cpu: "2"
          memory: 12Gi
        requests:
          cpu: 250m
          memory: 500Mi
    distribution:
      image: quay.io/opendatahub/llama-stack:rhoai-v3.4-ea2-latest
    userConfig:
      configMapName: llama-stack-config
```

---

## Generated llama-stack-config

```yaml
# Llama Stack Configuration
version: "2"
distro_name: rh
apis:
- agents
- datasetio
- files
- inference
- safety
- scoring
- tool_runtime
- vector_io
providers:
  inference:
  - provider_id: sentence-transformers
    provider_type: inline::sentence-transformers
    config: {}
  - provider_id: vllm-inference-1
    provider_type: remote::vllm
    config:
      api_token: ${env.VLLM_API_TOKEN_1:=fake}
      base_url: http://llama-32-1b-instruct-predictor.proj1.svc.cluster.local/v1
      max_tokens: ${env.VLLM_MAX_TOKENS:=4096}
      tls_verify: ${env.VLLM_TLS_VERIFY:=true}
  - provider_id: granite-embed-provider
    provider_type: remote::openai
    config:
      base_url: http://granite-embedding-r2-predictor.proj1.svc.cluster.local/v1
  vector_io:
  - provider_id: milvus
    provider_type: inline::milvus
    config:
      db_path: /opt/app-root/src/.llama/distributions/rh/milvus.db
      persistence:
        backend: kv_default
        namespace: vector_io::milvus
  - provider_id: pgvector-bff-provider
    provider_type: remote::pgvector
    config:
      db: vectordb
      distance_metric: COSINE
      host: pgvector2.pgvect.svc.cluster.local
      password: ${env.VS_CREDENTIAL_1:=}
      persistence:
        backend: kv_default
        namespace: vector_io::pgvector-bff-provider
      port: 5432
      user: vectoruser
registered_resources:
  models:
  - provider_id: sentence-transformers
    model_id: sentence-transformers/ibm-granite/granite-embedding-125m-english
    provider_model_id: ibm-granite/granite-embedding-125m-english
    model_type: embedding
    metadata:
      embedding_dimension: 768
  - provider_id: vllm-inference-1
    model_id: llama-32-1b-instruct
    model_type: llm
    metadata:
      description: ""
      display_name: llama-3.2-1b-instruct
  - provider_id: granite-embed-provider
    model_id: RedHatAI/granite-embedding-english-r2
    model_type: embedding
    metadata:
      display_name: Granite Embedding English R2 (RedHatAI)
      embedding_dimension: 768
  shields: []
  vector_stores:
  - vector_store_id: vs_bff00003-0000-0000-0000-000000000001
    embedding_model: RedHatAI/granite-embedding-english-r2
    embedding_dimension: 768
    provider_id: pgvector-bff-provider
    vector_store_name: BFF Test Knowledge Base (Remote Embedding)
    metadata:
      description: Test vector store using remote vLLM-hosted granite embedding model
  datasets: []
  scoring_fns: []
  benchmarks: []
  tool_groups:
  - toolgroup_id: builtin::rag
    provider_id: rag-runtime
server:
  port: 8321
```

---

## Install request

```bash
TOKEN=$(oc whoami -t)

curl -s -X POST "http://localhost:8080/api/v1/lsd/install?namespace=proj1" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "models": [
      {"model_name": "llama-32-1b-instruct", "model_source_type": "namespace"},
      {"model_name": "RedHatAI/granite-embedding-english-r2", "model_source_type": "custom_endpoint"}
    ],
    "vector_stores": [
      {"vector_store_id": "vs_bff00003-0000-0000-0000-000000000001"}
    ]
  }' | jq .
```
