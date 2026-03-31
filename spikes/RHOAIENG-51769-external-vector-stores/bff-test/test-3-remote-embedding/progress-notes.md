# Test-3 Progress Notes

## Status: RESOLVED

---

## Resolution Summary

The test was blocked on a `ModelNotFoundError` during vector store registration. Two separate fixes were required to get to a working state:

### Fix 1 — `provider_model_id` identifier mismatch (BFF)

**Root cause**: LlamaStack builds a model's internal identifier as `f"{provider_id}/{provider_model_id}"`. Our custom endpoint embedding model had `provider_model_id` empty (not set by `NewModel`), so the stored identifier was `granite-embed-provider/` (or similar). When LlamaStack's `register_vector_store` called `lookup_model("RedHatAI/granite-embedding-english-r2")` it found no match.

**Fix**: BFF commit `55a78938d` added lookup-table logic in `token_k8s_client.go`:
```go
effectiveProviderModelID = m.ProviderModelID  // falls back to m.ModelID if empty
identifier = fmt.Sprintf("%s/%s", m.ProviderID, effectiveProviderModelID)
```
Both `model_id` and `provider_model_id` are now registered as lookup keys, so LlamaStack can find the model by either.

### Fix 2 — Provider type: `remote::openai` → `remote::passthrough`

**Root cause**: Using `remote::openai` for an internal KServe InferenceService (no auth) worked for LlamaStack model registration, but the model was not visible in the AI Assets UI. `computeEmbeddingModelStatus` checks the custom endpoints configmap (`gen-ai-aa-custom-model-endpoints`) to determine if a model is available. The function correctly excluded the model from the "available" list when the configmap entry used `remote::openai` (an LLM-style provider, not a passthrough embedding provider).

Additionally, file ingestion via `POST /v1/vector_stores/{id}/files` fails with `remote::passthrough` providers because LlamaStack spawns an async background task that loses the request context (and therefore the `X-LlamaStack-Provider-Data` header with the API key). This is not actually a problem here since the KServe endpoint has no authentication — but ingestion was worked around regardless (see below).

**Fix**: Changed provider type to `remote::passthrough`, removed the `api_key` secretRef (not needed for internal KServe with no auth). Base URL has no `/v1` suffix.

### Fix 3 — Data ingestion via direct pgvector insert

File ingestion via the BFF upload API fails for `remote::passthrough` providers (see Known Issues below). Instead, embed the test content externally (by port-forwarding to the KServe service) and insert directly into pgvector.

---

## What works

- `granite-embedding-r2-predictor` InferenceService is **2/2 Ready** in `proj1`
- `/v1/embeddings` returns correct 768-dim vectors
- LSD installs successfully via UI with granite model selected
- `llama-stack-config` has `remote::passthrough` for `granite-embed-provider`
- Vector store `vs_bff00003-0000-0000-0000-000000000001` is registered in LlamaStack
- Test data is ingested via direct pgvector insert
- RAG query via the playground UI returns the correct context

---

## Known Issues

### `remote::passthrough` cannot support async file ingestion

LlamaStack's `POST /v1/vector_stores/{id}/files` spawns an async background task. The `remote::passthrough` provider calls `get_request_provider_data()` which reads the `X-LlamaStack-Provider-Data` header — but that header (and the request context) is gone by the time the background task runs.

```
ValueError: Pass API Key for the passthrough endpoint in the header
X-LlamaStack-Provider-Data as { "passthrough_api_key": <your api key>}
```

For the internal KServe endpoint (no auth), this would manifest as a missing passthrough key even though no key is needed. The workaround is direct pgvector insert with pre-computed embeddings.

**For synchronous RAG queries** (via the playground responses API): the BFF's `lsd_responses_handler.go` injects `passthrough_url` and `passthrough_api_key` into the provider data header, so query-time embedding works correctly.

---

## LlamaStack image

- **Required**: `quay.io/opendatahub/llama-stack:rhoai-v3.4-ea2-latest`
  - Has PR #5014 (merged March 6 2026): `model_validation` defaults to `false`, so `register_model`
    skips the `/v1/models` availability check
- **Old image** (`latest`): model_validation always runs → use the ea2 image

Set in `.env.local`:
```
DISTRIBUTION_NAME=quay.io/opendatahub/llama-stack:rhoai-v3.4-ea2-latest
```
