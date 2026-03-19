# Vector Stores Table Test Setup

This folder contains all YAML files needed to reproduce the four embedding model status
scenarios shown in the Vector Stores table on the AI Assets page.

## Prerequisites

- A running OpenShift cluster with ODH / gen-ai dashboard deployed
- An existing `proj1` namespace with an LSD (`lsd-genai-playground`) already deployed
- The BFF and frontend changes from this spike applied (include_embedding_models flag)

## Test Scenarios

The setup produces four vector store rows, each demonstrating a different embedding model status:

| Vector Store Name                    | Embedding Model                                            | Status          | UI Behavior                                         |
|--------------------------------------|------------------------------------------------------------|-----------------|-----------------------------------------------------|
| Product Docs RAG Store               | non-existent-embedding-model                               | `not_available` | "Missing model" warning, disabled button            |
| Granite Embedding RAG Store          | sentence-transformers/ibm-granite/granite-embedding-125m-english | `registered` | Green check, "Embedding model registered in LlamaStack playground" tooltip |
| External Embedding RAG Store         | test-fake-external-embedding                               | `available`     | No warning, "Add to playground" button              |
| Registered External Embedding RAG Store | test-fake-registered-external-embedding                 | `registered`    | Green check, "Embedding model registered in LlamaStack playground" tooltip |

## Apply Order

Apply in this order:

```bash
# 1. Deploy pgvector in the pgvect namespace (cross-namespace provider test)
kubectl apply -f 01-pgvect-pgvector.yaml

# After pgvector2 pod is running, create the vector extension as superuser:
oc exec -n pgvect deployment/pgvector2 -- psql -U postgres -d vectordb -c "CREATE EXTENSION IF NOT EXISTS vector;"

# 2. Register the fake external embedding models (simulates "Create external endpoint" modal)
kubectl apply -f 02-gen-ai-aa-external-models.yaml -n proj1

# 3. Apply the vector stores ConfigMap
kubectl apply -f 03-gen-ai-aa-vector-stores.yaml -n proj1

# 4. Patch llama-stack-config to add external-model-provider-2 and register
#    test-fake-registered-external-embedding so it appears in llamastack's model list.
#    NOTE: This ConfigMap is owned by the LSD operator. Apply carefully — the operator
#    may overwrite changes. After patching, restart the LSD pod:
kubectl apply -f 04-llama-stack-config.yaml -n proj1
oc rollout restart deployment/lsd-genai-playground -n proj1
```

## How the Embedding Model Status is Computed

The frontend function `computeEmbeddingModelStatus` checks two model lists:

- **`playgroundModels`**: Models returned by `/lsd/models?include_embedding_models=true`
  (llamastack's registered model list, including inline and external embedding models)
- **`allModels`**: Models from AI asset endpoints (the `gen-ai-aa-external-models` ConfigMap)

Status logic:
1. If found in `playgroundModels` → `registered` (green check)
2. Else if found in `allModels` → `available` (no warning)
3. Else → `not_available` ("Missing model" warning)

## Notes

- In the production flow, the BFF reads secrets referenced in `gen-ai-aa-vector-stores` via
  `secretRefs` and injects their values into `llama-stack-config` as env vars when creating or
  updating a playground — the llamastack pod then reads them at runtime. In this local test,
  `pgvector-credentials-2` is placed in the `pgvect` namespace as a workaround since that
  injection flow is not yet implemented.
- The `llama-stack-config` ConfigMap is managed by the LSD operator. The changes in
  `04-llama-stack-config.yaml` add `external-model-provider-2` (a fake remote::vllm provider)
  so that `test-fake-registered-external-embedding` can be registered in llamastack without
  an actual running endpoint (remote::vllm doesn't verify connectivity at startup).
- Port-forward to llamastack (port 8321) must be running for the BFF to fetch models.
  If the LSD pod restarts, restart the port-forward too.
