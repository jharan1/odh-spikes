# Sandbox Embedding Models — E2E Verification Setup (RHOAIENG-101172)

Reproduces the end-to-end verification of the sandbox-side fix for
[RHOAIENG-101172](https://issues.redhat.com/browse/RHOAIENG-101172) —
*deployed agent sandboxes return empty file-search results for vector stores
whose embedding models are not local HuggingFace models* — against a live
cluster running the fix's gen-ai BFF image.

Branch under test: `fix/RHOAIENG-101172-sandbox-static-embedding-providers`
(based on `main`; **no dependency on the RHOAIENG-100933 playground PR**).

## The bug

`BuildSandboxLlamaStackConfig` registered *every* vector-store embedding model
under the inline `sentence-transformers` provider. For external models
(keyed or keyless custom endpoints, ISVC-served models) OGX then attempted an
offline HuggingFace download at query time, which failed — silently returning
empty file-search results through the agent's `/v1/responses` route. The same
stores worked in the playground because the playground's OGX config registers
them correctly.

## The fix (what this E2E verifies)

Each referenced store's embedding model is classified at deploy time and
registered under a dedicated provider in the sandbox's
`llama-stack-config-*` ConfigMap, pointing **directly** at the model's
endpoint — the sandbox is standalone, with no runtime dependency on the
dashboard's genai-proxy for embeddings:

| Model source | Provider registered | Auth |
|---|---|---|
| Custom endpoint (keyed) | `agent-embedding-N` = `remote::passthrough`, base URL `/v1`-stripped | deploy-time Secret snapshot → deployment-owned Secret → `AGENT_EMBEDDING_API_KEY` env → the wrapper injects `passthrough_api_key` provider data (same mechanism as `AGENT_MODEL_API_KEY`/`openai_api_key` for the LLM) |
| Custom endpoint (keyless) | same `remote::passthrough` shape | static config `api_key: fake` — OGX's passthrough adapter cannot issue unauthenticated requests (the OpenAI SDK rejects an empty api_key with no `Authorization` header); endpoints without auth ignore the header. Mirrors the BFF's `fetchSecretFromProvider` "fake" default |
| ISVC / LLMInferenceService | `agent-embedding-N` = `remote::vllm`, ISVC URL including `/v1` (playground parity) | none (vLLM `NO KEY REQUIRED`) |
| Local HuggingFace | inline `sentence-transformers` (unchanged) | n/a |

Cluster-local providers (custom endpoint and ISVC alike) set
`network.tls.verify` to the OpenShift service-serving CA bundle projected into
every pod's service-account volume
(`/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt`) — TLS
verification is never disabled, and the API key never travels over an
unverified channel. The sandbox env no longer sets `VLLM_TLS_VERIFY=false`
(it was cargo-culted from the playground install path; OGX migrates the
deprecated `tls_verify` field into `network.tls.verify`, so it really did
disable verification for `remote::vllm` providers).

A sandbox installs a **single** embedding API key: referencing keyed
custom-endpoint embedding models backed by *different* Secrets is rejected at
deploy time (HTTP 400).

Query-time flow exercised per agent:

```
caller -> agent route /v1/responses (JWT, SSAR get-sandboxes — the ONLY
  authorization the caller needs; no ogxserver/secret reads at runtime)
    -> file_search -> embedding via agent-embedding-N (direct to the endpoint,
       authenticated per the table above)
    -> LLM via passthrough-llm (remote::openai) -> MaaS gateway (ephemeral token)
  -> answer containing the ingested weather content
```

## Test matrix

| Agent | Vector store | Embedding model | What it proves |
|---|---|---|---|
| `agent-keyed-vs` | `vs-e2e-gemini-keyed` | `gemini-embedding-001` (3072d), custom endpoint → Google | the core fix: static passthrough registration + the deploy-time API key snapshot reaching Google as `Authorization: Bearer` |
| `agent-keyless-vs` | `vs-e2e-granite-keyless-ce` | `granite-embedding-keyless` (768d), custom endpoint → in-cluster ISVC | keyless custom endpoints work with the placeholder config api_key |
| `agent-isvc-vs` | `vs-e2e-granite-isvc` | `granite-embedding-r2` (768d), namespace ISVC | ISVC-served models register as `remote::vllm` and authenticate none |
| `agent-namespaced-vs` | `vs-e2e-granite-namespaced-ce` | `RedHatAI/granite-embedding-english-r2` (768d), custom endpoint → ISVC | namespaced (HF-style) model IDs are preserved verbatim (provider-qualified reference and request body) |
| `agent-llmisvc-servedref` | `vs-e2e-llmisvc-servedref` | `granite-embedding-alias` (768d) — the LLMISVC **served model name** (`spec.model.name`), ≠ resource name `granite-embed-llmisvc` | served-name references resolve to the LLMInferenceService (second-pass `spec.model.name` match) and register under the served name |
| `agent-llmisvc-resref` | `vs-e2e-llmisvc-resref` | `granite-embed-llmisvc` — the LLMISVC **resource name** | resource-name references resolve too, and register under the *served* name (`granite-embedding-alias`), matching playground behavior when `spec.model.name` differs |

B, C and D deliberately share one vLLM ISVC (it serves all three names) — the
same granite model reached through different registration paths.

## Prerequisites

- OpenShift cluster with RHOAI 3.6+ and the gen-ai dashboard deployed
- The **fix's gen-ai BFF image** deployed (`quay.io/<user>/odh-mod-arch-gen-ai:dev`
  built from the branch; `RELATED_IMAGE_ODH_MOD_ARCH_GEN_AI_IMAGE` on the
  dashboard-operator — see the `cluster-deploy-genai` skill)
- Cluster-admin `oc` login, `jq` locally
- The cluster setup from the
  [RHOAIENG-100933 spike](../RHOAIENG-100933-proxy-routed-embedding-e2e):
  this verification reuses its namespace, Secrets, ISVC, ConfigMaps, chat LLM,
  playground (as the ingestion vehicle) and pgvector stores. Run **steps 1–8**
  of that spike's apply order first (everything through `ingest-weather.sh`).

## Procedure

```bash
export NAMESPACE=embedding-e2e-100933
export DASHBOARD_URL=https://rh-ai.apps.<your-cluster-domain>   # from: oc get cm gen-ai-params -n redhat-ods-applications -o jsonpath='{.data.dashboard-url}'

# after the RHOAIENG-100933 spike's steps 1-8 (setup + playground install + ingest):

# 1. Create one AgentProfile + one agent deployment per store (the code path
#    under test: BuildSandboxLlamaStackConfig + the embedding key Secret flow
#    in CreateAgentDeploymentHandler). Re-running requires deleting the
#    sandboxes first (deployment names are unique per project):
oc delete sandbox --all -n "$NAMESPACE"
./deploy-agents.sh

# 2. RAG chat E2E through each agent's own /v1/responses route + pod log check
./agent-chat-test.sh
```

## Expected results

**Generated sandbox configs** (per agent, `llama-stack-config-*` ConfigMap):
`agent-embedding-1` = `remote::passthrough` (keyed/keyless/namespaced CE
agents, base URLs without trailing `/v1`) or `remote::vllm` (ISVC agent, URL
with `/v1`); the store binds to `agent-embedding-1/<model-id>`; NO
`sentence-transformers/<external-model>` registration;
`vector_stores.default_embedding_model` points at `agent-embedding-1`.

**Env vars**: `AGENT_EMBEDDING_API_KEY` present **only** on the keyed agent,
sourced from a deployment-owned Secret (`agent-model-auth-*`) whose value
matches the Google API key.

**`agent-chat-test.sh`**: `PASS` for all four agents — `file_search_call`
completed with ≥1 retrieved chunk (scores: gemini ≈3.35, granite ≈10.1), the
answer quotes the weather content, and the agent pod logs contain **zero**
`Failed to search vector store` errors.

**Negative test** (keyed path): corrupt the `gemini-embedding-api-key` Secret,
deploy a fresh agent against the keyed store, and chat — the pod log shows
Google's `400 Please pass a valid API key` (proving the deploy-time snapshot →
env → wrapper → `Authorization` chain), and retrieval returns 0 chunks.
Restore the Secret and delete the test agent afterwards. Note the snapshot is
taken at deploy time: corrupting the source Secret does **not** affect already
deployed agents (they keep the key they were deployed with).

### Verified run

2026-10-21 on `jhrhoai-jenk` (RHOAI 3.6.0), BFF image
`quay.io/johnh/odh-mod-arch-gen-ai:dev` built from branch
`fix/RHOAIENG-101172-sandbox-static-embedding-providers` including the
review-fix commits (TLS service-CA verification, sandbox vLLM TLS fix,
key-ref validation fail-fast):

| Check | Result |
|---|---|
| Generated config: keyed CE model under `agent-embedding-1` (`remote::passthrough`), no sentence-transformers registration for it, no network block (external URL, public-CA verification) | ✅ |
| Generated config: keyless CE + namespaced CE models under `agent-embedding-1` (`remote::passthrough`) | ✅ |
| Generated config: ISVC model under `agent-embedding-1` (`remote::vllm`, ISVC URL with `/v1`) | ✅ |
| Generated config: passthrough base URLs carry no trailing `/v1`; cluster-local endpoints get `network.tls.verify: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt` (no more `verify: false`) | ✅ |
| Generated config: vLLM provider carries the same service-CA `network.tls.verify` and no deprecated `tls_verify` key | ✅ |
| Sandbox env: no `VLLM_TLS_VERIFY` (removed); `service-ca.crt` confirmed present in the sandbox pod's service-account volume | ✅ |
| `AGENT_EMBEDDING_API_KEY` present only on the keyed agent, value matches the Google key | ✅ |
| Chat E2E keyed store (Gemini via passthrough + env-sourced key) — 1 chunk (score ≈3.35), answer cites weather | ✅ |
| Chat E2E keyless CE store — 1 chunk (score ≈10.1), answer cites weather | ✅ |
| Chat E2E namespace ISVC store (remote::vllm) — 1 chunk (score ≈10.1), answer cites weather | ✅ |
| Chat E2E namespaced CE store (model id preserved verbatim) — 1 chunk, answer cites weather | ✅ |
| LLMISVC served-name reference (`granite-embedding-alias` ≠ resource name): resolves via `spec.model.name` match, registers under the served name | ✅ |
| LLMISVC resource-name reference: resolves by resource name, registers under the served name (playground parity) | ✅ |
| Chat E2E LLMISVC served-name store — 1 chunk (score ≈12.7), answer quotes the weather report with citation | ✅ |
| Chat E2E LLMISVC resource-name store — 1 chunk, answer cites weather | ✅ |
| Agent pod logs free of `Failed to search vector store` (all agents incl. both LLMISVC ones) | ✅ (0 occurrences) |
| Negative test: corrupt key → fresh agent → chat returns 0 chunks and the pod log shows Google `400 Please pass a valid API key` (also reproducible via a direct `/v1/embeddings` probe with the corrupted `passthrough_api_key`); already-deployed agents unaffected; restore → clean | ✅ |
| Go unit tests (`internal/integrations/kubernetes/...`) + golangci-lint | ✅ |

### Verified run — local sentence-transformers path (2026-10-21, follow-up)

The matrix above covers remote-backed models only; a follow-up run on
`jhrhoai-jenk` verified the **built-in local HF path** end-to-end (fresh
namespace `embedding-e2e-local`, same BFF image, chat LLM reused from the
`tracing` namespace's MaaS `gemini-proxy`):

| Check | Result |
|---|---|
| Store `vs-e2e-local-st` (embedding model `ibm-granite/granite-embedding-125m-english`, 768d) classifies as local — no ISVC/CE lookup hit, no `agent-embedding-N` provider created | ✅ |
| Generated config: model registered under the inline `sentence-transformers` provider (`provider_model_id: ibm-granite/granite-embedding-125m-english`), store bound to it, `default_embedding_model` repointed | ✅ |
| `/v1/embeddings` through the sandbox route loads the model in-process from the baked HF cache and returns 768-dim vectors | ✅ |
| Chunk ingested via the sandbox's own `/v1/vector-io/insert` (after hand-creating the `vs_vs_e2e_local_st` table — see findings) | ✅ |
| Chat E2E — file_search `completed`, 1 chunk (score ≈9.68), answer quotes the weather report with `<\|weather-doc-001\|>` citation | ✅ |
| Pod log: 0 `Failed to search vector store`; `Loading sentence transformer for ibm-granite/...` at query time | ✅ |

Findings from this run:

- **Sandboxes are HF-offline by design**: the (pre-existing) sandbox env pins
  `HF_HUB_OFFLINE=1`/`TRANSFORMERS_OFFLINE=1`/`HF_DATASETS_OFFLINE=1`, so only
  models pre-baked into the sandbox image work locally — currently
  `ibm-granite/granite-embedding-125m-english` (768d), `nomic-ai/nomic-embed-text-v1.5`,
  and `Qwen/Qwen3-Reranker-0.6B`. A store referencing any other local HF model
  (e.g. `sentence-transformers/all-MiniLM-L6-v2`) fails at runtime with an offline-mode
  download error — pre-existing behavior, unchanged by this PR. The config-level
  registration for such a store is still generated correctly (verified with
  `all-MiniLM-L6-v2` before switching to the pre-baked model).
- **`granite-embedding-125m-english` is 768-dim** — a store's `embedding_dimension`
  must match or pgvector insert/query fails on the vector(N) column.
- **OGX pgvector insert does not auto-create tables**: the per-store table
  (`vs_<id>`: `id text PRIMARY KEY, document jsonb, embedding vector(N),
  content_text text, tokenized_content tsvector`) must exist; the insert SQL uses
  `ON CONFLICT (id)` so `id` needs the PK/unique constraint. (The playground path
  creates tables during install; sandbox-only stores don't have that step.)
- **Stale MaaS modelRefs can empty the whole catalog**: after the original E2E
  namespace was deleted, `gemini-subscription` still referenced
  `embedding-e2e-100933/gemini-proxy` → subscription `Failed` ("all model
  references are invalid or unavailable") → the MaaS catalog listed zero models,
  breaking *all* MaaS installs cluster-wide. Fix: remove stale refs from
  `maassubscription`/`maasauthpolicy` (and the orphaned `maasmodelref`).
- **Orphaned namespaced objects after a forced namespace deletion**: deleting a
  namespace that was force-removed leaves objects in etcd that still LIST
  cluster-wide but return NotFound on delete. Fix: re-create the namespace, delete
  the objects, then delete the namespace again.

Note: the cluster-local E2E endpoints are plain `http://`, so the service-CA
path is verified by config inspection + projected-file presence rather than
a runtime TLS handshake; the OTel exporter in the same repo relies on the
same projected `service-ca.crt` for its in-cluster TLS.

## Findings from the verified run

- **Keyless passthrough needs a placeholder api_key** (bug found by this E2E,
  fixed in the branch): with no credential at all, OGX's passthrough adapter
  fails inside the OpenAI SDK header validation
  (`TypeError: Could not resolve authentication method`) and file_search
  swallows it as empty results. The fix pins `api_key: fake` for keyless
  custom-endpoint providers. The playground never hit this because its BFF
  always sends `passthrough_api_key` (the user JWT) on every request.
- **MaaS LLM profile URI**: must be the catalog model URL
  (`https://maas.apps.<domain>/` — `BuildSandboxLlamaStackConfig` normalizes
  to `/v1`), NOT the `/maas-api` gateway control path (that path is only for
  token issuance via the wrapper's `MAAS_GATEWAY_URL`). Using `/maas-api`
  makes every chat request fail with a Go-style `404 page not found` from the
  MaaS gateway.
- **Namespace resurrection hazard**: if the namespace was previously deleted
  but the deletion got stuck, re-creating it can resurrect stale objects whose
  dependencies (ConfigMaps/Secrets) were already purged (e.g. a pgvector
  deployment stuck `ContainerCreating` on a missing `genai-pgvector-init`
  ConfigMap). Fix: delete the stale deployments/PVC/routes/sandboxes before
  installing.
- **Deployment name uniqueness**: agent deployment names are unique per
  project — re-running `deploy-agents.sh` needs
  `oc delete sandbox --all -n $NAMESPACE` (or per-agent) first, else HTTP 409.
- **LLMInferenceService routes are protected by Kuadrant AuthPolicy by design**: the
  `odh-model-controller` creates an AuthPolicy (kubernetes-user TokenReview authn)
  for every Gateway an LLMInferenceService attaches to — the `401` on gateway URLs
  without a token is intentional model-serving governance, not a bug, and affects
  the playground's namespace-model path identically (the reason the e2e chat LLM
  uses MaaS). To unblock the sandbox chat E2E on a dev cluster: create a plain
  `openshift-default`-class Gateway in the test namespace, point the LLMISVC's
  `spec.router.gateway.refs` at it, scale `deploy/odh-model-controller` (redhat-ods-applications)
  to 0, delete the auto-created AuthPolicy, and scale the controller back up after
  testing (it recreates the policy). Kuadrant AuthPolicy is deny-by-default for its
  target — patching the path patterns is not enough; the policy must be absent.
  With that, the full chain works pod-to-pod: store reference → `spec.model.name`
  match → `agent-embedding-1/granite-embedding-alias` (remote::vllm) → gateway →
  vLLM → 1 chunk (score ≈12.7) → answer quoting the weather report.

## OGX facts this design relies on (verified from the running OGX source)

- `remote::passthrough` auth chain: config `api_key` (takes precedence) →
  provider-data `passthrough_api_key` → `Authorization: Bearer <key>`;
  appends `/v1` to the configured base URL; implements `openai_embeddings`.
- Registered models always route to their own provider — adding a
  `remote::passthrough` embedding provider cannot hijack LLM routing (the
  "sole passthrough provider" fallback only applies to unregistered
  `provider/model` IDs).
- `remote::vllm` reads `vllm_api_token` (nobody sets it) → `NO KEY REQUIRED`
  → no auth header — correct for unauthenticated ISVC predictors.

## Cleanup

```bash
# remove just the agents (keeps the shared setup from the 100933 spike):
oc delete sandbox --all -n embedding-e2e-100933
# remove everything (shared setup included — see the 100933 spike):
oc delete namespace embedding-e2e-100933
```

## Files

| File | Purpose |
|---|---|
| `deploy-agents.sh` | create one AgentProfile + agent deployment per store via the BFF API, wait for sandbox readiness |
| `agent-chat-test.sh` | RAG chat E2E per agent through its own `/v1/responses` route (file_search + answer + citations) + pod log check |
