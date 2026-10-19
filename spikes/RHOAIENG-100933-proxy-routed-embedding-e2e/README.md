# Proxy-Routed Embedding Models — E2E Verification Setup (RHOAIENG-100933)

Reproduces the full end-to-end verification of
[odh-dashboard PR #10314](https://github.com/opendatahub-io/odh-dashboard/pull/10314)
(*fix(gen-ai): route custom-endpoint embedding models through genai-bff-proxy*)
against a live cluster running the PR's gen-ai BFF image.

This spike covers the **cluster-side setup and test procedure** only.

## What is being verified

Before the fix, custom-endpoint embedding models were registered as **direct
providers with only a `base_url`** — no credentials ever reached the playground
config, so query-time embedding calls forwarded the user's JWT (or nothing) to
the external endpoint. Keyed endpoints (e.g. Gemini via Google) rejected it:
`400 Please pass a valid API key` → silent "no results" in chat.

The fix registers custom-endpoint embedding models under the existing
**`genai-bff-proxy`** passthrough provider (keyed *and* keyless alike), so
query-time embedding requests route through the BFF's genai-proxy, which
resolves the real endpoint + credentials per request.

### Test matrix

| # | Model | Source | Key | What it proves |
|---|---|---|---|---|
| A | `gemini-embedding-001` (3072d) | custom endpoint → Google | **keyed** (Secret ref) | the fix: proxy routes + resolves the Secret-sourced API key |
| B | `granite-embedding-keyless` (768d) | custom endpoint → in-cluster ISVC | **keyless** | the scope decision: keyless custom endpoints take the same proxy path |
| C | `granite-embedding-r2` (768d) | **namespace ISVC** (vLLM) | keyless (JWT) | no regression: namespace models keep the static `remote::vllm` provider |

B and C deliberately share one vLLM ISVC (it serves two model names) — the
*same granite model* reached two ways: through the proxy (custom endpoint
declaration) and direct (namespace model). The model IDs differ
(`granite-embedding-keyless` vs `granite-embedding-r2`) so that
`buildEmbeddingModelLookup` can't confuse the two stores.

## Architecture

```
embedding-e2e-100933 namespace
├── granite-embedding-r2 (kserve InferenceService, RawDeployment)
│     └── vLLM CPU pod: RedHatAI/granite-embedding-english-r2
│         serves BOTH names: granite-embedding-r2 + granite-embedding-keyless
│         (keyless http://...predictor...:8080 — nothing to authenticate with)
├── Secret: gemini-embedding-api-key            ← Google API key (NOT committed)
├── ConfigMap: gen-ai-aa-custom-model-endpoints ← keyed Gemini + keyless granite providers
├── ConfigMap: gen-ai-aa-vector-stores          ← 3 pgvector-backed stores, one per model
├── genai-pgvector (auto-provisioned by the BFF install, pgvector credentials Secret)
└── lsd-genai-playground (OGXServer) — generated llama-stack-config:
      models:
        genai-bff-proxy/gemini-embedding-001        (A — proxy-routed, THE FIX)
        genai-bff-proxy/granite-embedding-keyless   (B — proxy-routed)
        vllm-inference-3/granite-embedding-r2       (C — static direct provider, unchanged)
      vector_stores:
        vs-e2e-gemini-keyed        -> genai-bff-proxy/gemini-embedding-001
        vs-e2e-granite-keyless-ce  -> genai-bff-proxy/granite-embedding-keyless
        vs-e2e-granite-isvc        -> vllm-inference-3/granite-embedding-r2
```

Query-time flows being exercised:

```
A: playground -> genai-bff-proxy -> BFF genai-proxy (JWT) -> Google (Secret-sourced key)
B: playground -> genai-bff-proxy -> BFF genai-proxy (JWT) -> ISVC (no auth header)
C: playground -> vllm-inference-3 -> ISVC direct (no BFF involved)
```

## Prerequisites

- OpenShift cluster with RHOAI 3.6+ and the gen-ai dashboard deployed
- The **PR's gen-ai BFF image** deployed (see the `cluster-deploy-genai` skill /
  deploy `quay.io/<user>/odh-mod-arch-gen-ai:dev` and set
  `RELATED_IMAGE_ODH_MOD_ARCH_GEN_AI_IMAGE` on the dashboard-operator)
- Cluster-admin `oc` login (`oc whoami`)
- `jq` locally
- A Google API key with the Generative Language API enabled (the
  `gemini-secret` in the `tracing` namespace works, if present)
- HuggingFace egress from the cluster (the ISVC downloads the granite model at
  startup — verify with a curl pod if in doubt)

## Apply order

```bash
export NAMESPACE=embedding-e2e-100933
export DASHBOARD_URL=https://rh-ai.apps.<your-cluster-domain>   # from: oc get cm gen-ai-params -n redhat-ods-applications -o jsonpath='{.data.dashboard-url}'

# 1. Namespace (label makes it visible to the dashboard)
oc apply -f 01-namespace.yaml

# 2. Gemini API key Secret — put the REAL key in first (file is gitignored by pattern *key.yaml)
oc apply -f 02-gemini-embedding-api-key.yaml

# 3. Granite embedding ISVC (vLLM CPU) — takes ~5 min to pull + download the model
oc apply -f 03-isvc-granite.yaml
oc wait --for=condition=Ready isvc/granite-embedding-r2 -n $NAMESPACE --timeout=600s
# sanity: both served names must work
POD=$(oc get pods -n $NAMESPACE -o name | grep granite-embedding-r2-predictor | sed 's|pod/||')
oc exec -n $NAMESPACE $POD -c kserve-container -- curl -s localhost:8080/v1/embeddings \
  -H 'Content-Type: application/json' -d '{"model":"granite-embedding-r2","input":"ping"}' | jq '.data[0].embedding | length'   # 768
oc exec -n $NAMESPACE $POD -c kserve-container -- curl -s localhost:8080/v1/embeddings \
  -H 'Content-Type: application/json' -d '{"model":"granite-embedding-keyless","input":"ping"}' | jq '.data[0].embedding | length' # 768

# 4/5. ConfigMaps: custom model endpoints (keyed + keyless) and the three vector stores
oc apply -f 04-custom-model-endpoints-cm.yaml -f 05-vector-stores-cm.yaml

# 6. Install the playground via the BFF API (two-phase, see script header for why)
./install-playground.sh

# 7. Ingest the weather test chunk into all three stores (pre-computed embeddings)
./ingest-weather.sh

# 8. Query all three stores through the file_search code path
./query-stores.sh

# 9. Prove per-request Secret resolution on the keyed path
./negative-test-keyed.sh
```

## Expected results

**Config shape** (printed by `install-playground.sh`): see the Architecture
section — the assertions that matter are *no direct provider entries* for the
custom-endpoint providers, and the three vector store bindings above.

**`query-stores.sh`**: `PASS` for all three stores — the weather chunk
("sunny, high of 25 degrees…") is retrieved from each, and the playground log
contains **zero** `Failed to search vector store` errors.

**`negative-test-keyed.sh`**: with the Secret's key corrupted, the keyed query
fails with `400 'Please pass a valid API key'` (the bug's *symptom* — but now
it proves the request reached Google via the BFF with the Secret-sourced key);
after restoring, the query succeeds again. Combined with the playground pod
holding no Google credentials, this proves per-request credential resolution
through the proxy.

### Verified run

2026-10-19 on `jhrhoai-jenk` (RHOAI 3.6.0), BFF image
`quay.io/johnh/odh-mod-arch-gen-ai:dev` built from PR head `02315ef5a`:

| Check | Result |
|---|---|
| Generated config: keyed CE model under `genai-bff-proxy`, no direct provider | ✅ |
| Generated config: keyless CE model under `genai-bff-proxy` (identical shape) | ✅ |
| Generated config: namespace ISVC model under `vllm-inference-3` (unchanged) | ✅ |
| Query keyed store (Gemini) — chunk retrieved | ✅ |
| Query keyless CE store (granite via proxy) — chunk retrieved | ✅ |
| Query namespace ISVC store (granite direct) — chunk retrieved | ✅ |
| Playground logs free of `Failed to search vector store` | ✅ |
| Negative test: corrupt key → 400 `Please pass a valid API key`; restore → works | ✅ |
| Go unit tests (`internal/integrations/kubernetes/...`) | ✅ |

Not covered here (by design): chat-level `/v1/responses` + file_search E2E —
it needs an LLM registered in the playground; the `/v1/vector-io/query` path
used above is the same retrieval code path file_search executes, and
provider-data propagation is covered in the bug doc.

## Key implementation details (why things are the way they are)

- **Two-phase install**: `LoadAndValidateVectorStores` requires the pgvector
  credentials Secret to exist *before* install, but the Secret is created by
  the pgvector auto-provisioning *during* install. So: install (models only) →
  `DELETE /lsd/delete` with `preserve_vector_store: true` (strips pgvector
  owner refs so it survives the OGXServer delete) → install again with stores.
- **One ISVC, two model names**: `--served-model-name` is a `nargs="+"` arg —
  pass both names space-separated. Two distinct model IDs avoid the
  `buildEmbeddingModelLookup` collision (two registered models with the same
  bare id would make one store silently bind to the wrong provider).
- **Custom endpoint base_url for the keyless granite**:
  `http://granite-embedding-r2-predictor.<ns>.svc.cluster.local:8080` — the
  predictor Service is **headless** (ClusterIP: None) in RawDeployment, so the
  target port must be in the URL. The BFF embeddings handler appends
  `/v1/embeddings` when the base URL lacks `/v1`.
- **Gemini base_url** `https://generativelanguage.googleapis.com/v1beta/openai`
  works despite the BFF's `/v1` normalization — Google also serves
  `.../v1beta/openai/v1/embeddings`.
- **Query auth**: direct `/v1/vector-io/query` calls need the
  `x-ogx-provider-data: {"passthrough_api_key": <user JWT>}` header — exactly
  what the BFF's `getProviderData` injects for `/v1/responses` requests. It
  authenticates the playground → BFF proxy hop.
- **pgvector table naming**: OGX creates one table per store,
  `vs_<vector_store_id with dashes replaced by underscores>`, with columns
  `id, document (jsonb), embedding (vector(N)), content_text, tokenized_content`.
  The insert payload must be an `EmbeddedChunk` (see `ingest-weather.sh`).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| ISVC pod `ImagePullBackOff` on `quay.io/vllm/vllm:latest` | The OOTB `csr-kserve-vllm-cpu` ClusterServingRuntime references a **dead tag**. Use `quay.io/vllm/vllm-cpu:v0.31.0_rhaiv.2` (or newer `*.rhaiv` CPU tag). |
| vLLM `RuntimeError: Failed to infer device type` | CUDA-flavored vLLM image on a CPU node. Use the `vllm-cpu` repo image. |
| `--task=embed` unrecognized | Removed in newer vLLM; embedding task is auto-detected from the model architecture (ModernBert). |
| HF download fails with "no config file found" / `LocalEntryNotFoundError` | The vLLM images set `HF_HUB_OFFLINE=1` — override to `0` (and `TRANSFORMERS_OFFLINE=0`). |
| `PermissionError at /home/vllm/.cache/huggingface` | Restricted SCC random UID can't write the image user's home. Set `HF_HOME=/tmp/hf_home`. |
| `Insufficient space in /dev/shm ... 160 MiB required, 64 MiB free` | Mount a memory-backed emptyDir at `/dev/shm` (see `03-isvc-granite.yaml`). |
| `Available memory on node 0 ... less than desired CPU memory utilization` | vLLM CPU reserves `--gpu-memory-utilization` (default 0.92) of the container limit. Set `0.6` or raise the memory limit. |
| Pod restarts during model load | The liveness probe kills vLLM mid-download. Drop the liveness probe, keep readiness with a high `failureThreshold`. |
| `MissingMount ... secret ...-serving-cert not found` at ISVC creation | Transient — the service-ca controller creates the cert secret shortly after the Service. It resolves on the next pod start. |
| Install 400: `credential secret "genai-pgvector-credentials" not found` | You skipped phase 1 — the vector store validation runs before pgvector provisioning. Run the two-phase install. |
| Install 400: `OGXServer already exists in namespace; recreate it before adding vector stores` | Run the reconfigure-delete (`preserve_vector_store: true`) then reinstall — `install-playground.sh` phase 2a. |
| Query returns 0 chunks for ALL stores | Probably an empty/invalid JWT in `x-ogx-provider-data` (the BFF proxy then 401s). Use `oc whoami -t`. |

## Cleanup

```bash
oc delete namespace embedding-e2e-100933
```

(removes everything — ISVC, playground, pgvector + data, configmaps, secrets)

## Files

| File | Purpose |
|---|---|
| `01-namespace.yaml` | test namespace with the dashboard label |
| `02-gemini-embedding-api-key.yaml` | keyed-endpoint Secret (placeholder; gitignored by `*key.yaml`) |
| `03-isvc-granite.yaml` | granite embedding ISVC (vLLM CPU, dual served names, /dev/shm, HF overrides) |
| `04-custom-model-endpoints-cm.yaml` | `gen-ai-aa-custom-model-endpoints`: keyed Gemini + keyless granite providers |
| `05-vector-stores-cm.yaml` | `gen-ai-aa-vector-stores`: three pgvector-backed stores |
| `install-playground.sh` | two-phase BFF install + generated-config assertions |
| `ingest-weather.sh` | compute embeddings (Google + ISVC) and insert the weather chunk into each store |
| `query-stores.sh` | query all three stores through the file_search code path + log check |
| `negative-test-keyed.sh` | corrupt/restore the API key Secret to prove per-request resolution |
