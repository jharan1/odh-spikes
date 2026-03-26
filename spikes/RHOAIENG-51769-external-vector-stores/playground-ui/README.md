# Playground UI — External Vector Stores Test

This folder documents the end-to-end cluster and application setup used to test
external vector store selection in the Gen AI playground UI (compare mode).

**Branch**: `RHOAIENG-51775-enable-external-vector-stores-in-playground`
**Namespace**: `proj1`
**Date**: 2026-03-25

## Goal

Test the playground UI with the `ai-asset-vector-stores` feature flag enabled so
that each chat pane in compare mode can independently select an external vector
store for RAG, using the radio-button Knowledge tab UI.

## Cluster State

### Inference services (proj1)

| Name                    | Type      | Purpose                                                            |
|-------------------------|-----------|--------------------------------------------------------------------|
| `llama-32-3b-instruct`  | vLLM      | Main LLM for chat                                                  |
| `granite-embedding-r2`  | kServe    | Remote embedding model (unused here, encountered issue setting up) |

### pgvector (pgvect namespace)

| Resource   | Details                                           |
|------------|---------------------------------------------------|
| Deployment | `pgvector2` in `pgvect` namespace                 |
| Service    | `pgvector2.pgvect.svc.cluster.local:5432`         |
| DB         | `vectordb`, user `vectoruser`                     |
| Secret     | `pgvector-bff-credentials` in `proj1` (key: `password`) |

### LlamaStack Distribution (proj1)

| Resource              | Value                                          |
|-----------------------|------------------------------------------------|
| Name                  | `lsd-genai-playground`                         |
| Service               | `lsd-genai-playground-service:8321`            |
| Image                 | `quay.io/opendatahub/llama-stack:rhoai-v3.4-ea2-latest` |
| ConfigMap (generated) | `llama-stack-config`                           |

## Setup Steps

### 1. Create pgvector credentials secret

```bash
oc create secret generic pgvector-bff-credentials \
  --from-literal=password=vectorpass2 \
  -n proj1
```

### 2. Apply the vector stores ConfigMap

```bash
oc apply -f configmaps/gen-ai-aa-vector-stores.yaml
```

See [configmaps/gen-ai-aa-vector-stores.yaml](configmaps/gen-ai-aa-vector-stores.yaml).

### 3. Install the LSD

```bash
TOKEN=$(oc whoami -t) && curl -s -X POST "http://localhost:8080/api/v1/lsd/install?namespace=proj1" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "models": [
      {"model_name": "llama-32-3b-instruct", "model_source_type": "namespace"}
    ],
    "vector_stores": [
      {"vector_store_id": "vs_bff00001-0000-0000-0000-000000000001"},
      {"vector_store_id": "vs_bff00002-0000-0000-0000-000000000001"}
    ]
  }' | jq .
```

If the LSD already exists, delete it first:

```bash
oc delete llamastackdistribution lsd-genai-playground -n proj1
```

### 4. Port-forward LSD (for BFF to reach LlamaStack)

```bash
oc port-forward -n proj1 svc/lsd-genai-playground-service 8321:8321
```

### 5. Upload content to each vector store

**Weather Knowledge Base** (`vs_bff00001`):

```bash
TOKEN=$(oc whoami -t) && curl -s -X POST \
  "http://localhost:8080/api/v1/lsd/vectorstores/files/upload?namespace=proj1" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@content/weather.txt;type=text/plain" \
  -F "vector_store_id=vs_bff00001-0000-0000-0000-000000000001" | jq .
```

**Product Knowledge Base** (`vs_bff00002`):

```bash
TOKEN=$(oc whoami -t) && curl -s -X POST \
  "http://localhost:8080/api/v1/lsd/vectorstores/files/upload?namespace=proj1" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@content/products.txt;type=text/plain" \
  -F "vector_store_id=vs_bff00002-0000-0000-0000-000000000001" | jq .
```

Poll status:

```bash
TOKEN=$(oc whoami -t) && curl -s \
  "http://localhost:8080/api/v1/lsd/files/upload/status?namespace=proj1&job_id=<JOB_ID>" \
  -H "Authorization: Bearer $TOKEN" | jq .
```

## Frontend Feature Flag

The external vector store UI is gated by the `ai-asset-vector-stores` feature flag.
Enable it in the dashboard feature flags settings to see the Knowledge tab radio
buttons (inline upload vs external vector store).

## Test Scenarios

### Single pane — external vector store

1. Open playground, go to Knowledge tab
2. Enable the RAG toggle
3. Select "Use an existing vector store"
4. Select "Weather Knowledge Base"
5. Ask: **"What is the weather today?"**
   - Expected: answer mentions the content uploaded (sunny, 25°C, etc.)

### Compare mode — two different vector stores

1. Enable compare mode (Model 2 button)
2. In pane 1: Knowledge tab → RAG on → external → **Weather Knowledge Base**
3. In pane 2: Knowledge tab → RAG on → external → **Product Knowledge Base**
4. Ask: **"What is the weather today?"**
   - Pane 1: answers from weather knowledge
   - Pane 2: answers it doesn't know / off-topic
5. Ask: **"How much does the XPhone 15 cost?"**
   - Pane 1: answers it doesn't know / off-topic
   - Pane 2: answers "$999"

### RAG toggle — verify master control

1. Select any external vector store
2. Toggle RAG off
3. Ask the knowledge question
   - Expected: model answers without RAG context (generic/uncertain answer)
4. Toggle RAG back on and re-ask
   - Expected: model correctly uses the vector store context

---

## Manual Test Results (2026-03-26)

The following scenarios were tested end-to-end against the live cluster after the
`selectedSourceSettings.vectorStore` removal from `useChatbotMessages`.

### Scenario 1 — Inline RAG in compare mode, both panes share the same uploaded file

**Setup:**
- Pane 1: Knowledge tab → RAG on → "Use uploaded documents" → uploaded `color.txt`
  (contents: `The secret color is green.`)
- Pane 2: Knowledge tab → RAG on → "Use uploaded documents" (same inline store)

**Query:** "What is the secret color?"

**Result:** ✅ Both panes correctly answered "The secret color is green."

---

### Scenario 2 — Switch pane 2 to an external vector store

**Setup:** (continuing from Scenario 1)
- Pane 2: Knowledge tab → switch to "Use an existing vector store" → select **Product Knowledge Base**

**Query:** "What is the secret color?"

**Result:** ✅ Pane 1 answered correctly (green). Pane 2 correctly had no knowledge of the secret color.

---

### Scenario 3 — Query each pane's distinct knowledge

**Setup:** (same as Scenario 2)

**Query:** "How much is the XPhone 15?"

**Result:** ✅ Pane 1 (inline/color.txt) correctly had no knowledge of the XPhone 15 price.
Pane 2 (Product Knowledge Base) correctly returned the price ($999).

---

### Scenario 4 — Disable RAG on external pane

**Setup:** (continuing from Scenario 3)
- Pane 2: Knowledge tab → toggle RAG **off**

**Query:** "How much is the XPhone 15?"

**Result:** ✅ Pane 2 correctly had no knowledge of the price with RAG disabled.

---

### Scenario 5 — Fresh inline upload works correctly after `selectedSourceSettings` removal

**Context:** After removing `selectedSourceSettings?.vectorStore` from the RAG request
pipeline in `useChatbotMessages`, verified that inline file upload still works as
expected. `currentVectorStoreId` (sourced from `fileManagement`) now drives the
`vector_store_ids` parameter exclusively.

**Setup:**
- Pane 1: Knowledge tab → RAG on → upload a file via the inline panel
- (Also tested with a second compare pane open and the same query)

**Result:** ✅ Inline RAG responses were correct in both single-pane and compare mode.
