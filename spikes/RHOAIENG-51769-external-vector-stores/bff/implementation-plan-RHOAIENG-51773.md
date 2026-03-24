# Implementation Plan: Register External Vector Stores During BFF LSD Install

**Jira**: [RHOAIENG-51773](https://issues.redhat.com/browse/RHOAIENG-51773)
**Epic**: RHOAIENG-51472
**Branch**: `RHOAIENG-51773-register-external-vector-stores-in-bff-lsd-install`

---

## Overview

The story requires updating `LlamaStackDistributionInstallHandler` so that `LlamaStackDistributionInstallRequest` can optionally include vector stores. When supplied, the BFF reads the `gen-ai-aa-vector-stores` ConfigMap, validates those stores, injects their config into the generated LlamaStack distribution config, and resolves credential Secrets into env vars. The UI is responsible for including any required embedding models in the `Models` field of the same request — the BFF validates that each vector store's embedding model was included, but does not auto-register it. If no vector stores are provided, the install proceeds unchanged.

---

## 1. `models/llamastack_distribution.go`

Add `VectorStores` to `LlamaStackDistributionInstallRequest` and introduce `InstallVectorStore`:

```go
type LlamaStackDistributionInstallRequest struct {
    Models           []InstallModel       `json:"models"`
    EnableGuardrails bool                 `json:"enable_guardrails,omitempty"`
    VectorStores     []InstallVectorStore `json:"vector_stores,omitempty"` // NEW
}

// InstallVectorStore identifies a vector store to include in the LSD install.
type InstallVectorStore struct {
    VectorStoreID string `json:"vector_store_id"`
}
```

No validation changes needed in the handler for this field — empty/nil means "proceed without vector stores."

---

## 2. `integrations/kubernetes/client.go` (`KubernetesClientInterface`)

Two interface additions:

```go
// Add GetSecret for credential resolution
GetSecret(ctx context.Context, identity *integrations.RequestIdentity, namespace string, secretName string) (*corev1.Secret, error)

// Update InstallLlamaStackDistribution signature
InstallLlamaStackDistribution(
    ctx context.Context,
    identity *integrations.RequestIdentity,
    namespace string,
    models []models.InstallModel,
    enableGuardrails bool,
    vectorStores []models.InstallVectorStore, // NEW
    maasClient maas.MaaSClientInterface,
) (*lsdapi.LlamaStackDistribution, error)
```

---

## 3. `integrations/kubernetes/llamastack_config.go`

Add helpers:

- `RegisterVectorDB(db VectorDB)` — appends to `RegisteredResources.VectorDBs`, following the same pattern as `RegisterModel` / `RegisterShield`.
- `CredentialEnvVarField(providerType string) string` — maps provider type to the llamastack credential config field name:
  - `"qdrant"` → `"api_key"` (renders as `${env.VS_CREDENTIAL_N:=}`)
  - `"milvus"` → `"token"` (renders as `${env.VS_CREDENTIAL_N}`)
  - `"pgvector"` → `"password"` (renders as `${env.VS_CREDENTIAL_N}`)
  - unknown → `"api_key"` as a fallback
- `AddExternalVectorStoreProvider(providerID string, store ExternalVectorStoreConfig, credEnvVarRef string)` — creates and appends the appropriate `VectorIO` provider from the store's `ProviderType` and `Config`, injecting the credential env var ref if set.

---

## 4. `integrations/kubernetes/token_k8s_client.go`

This is the heaviest change. Key updates:

### 4a. Add `GetSecret` method

```go
func (kc *TokenKubernetesClient) GetSecret(ctx, identity, namespace, secretName) (*corev1.Secret, error)
```

Uses `kc.Client.Get()` — same pattern as `GetConfigMap`.

### 4b. Update `InstallLlamaStackDistribution` signature

Add `vectorStores []models.InstallVectorStore` parameter. When non-empty:

- Call `kc.loadAndValidateVectorStores(ctx, identity, namespace, vectorStores)` to get the validated `[]models.ExternalVectorStoreConfig` (see 4c).
- For each store that has a `CredentialSecret`, verify the secret exists and append a `SecretKeyRef` env var to `envVars`. Name the env var `VS_CREDENTIAL_<INDEX>` (1-based, matching the store's position in the request).
- Pass the loaded store configs into `generateLlamaStackConfig`.

### 4c. New `loadAndValidateVectorStores` method

```go
func (kc *TokenKubernetesClient) loadAndValidateVectorStores(
    ctx context.Context,
    identity *integrations.RequestIdentity,
    namespace string,
    vectorStores []models.InstallVectorStore,
) ([]models.ExternalVectorStoreConfig, error)
```

Steps:
1. `GetConfigMap(... constants.VectorStoresConfigMapName)` — return a clear error if not found: `"vector stores were supplied but the gen-ai-aa-vector-stores ConfigMap was not found in namespace %s"`.
2. Parse `stores.yaml` into `ExternalVectorStoresDocument`.
3. Build a `map[string]ExternalVectorStoreConfig` by store `Name`.
4. For each requested `InstallVectorStore`, look it up by `VectorStoreID`. Return `"vector store %q not found in ConfigMap"` if missing.
5. Validate each found store:
   - `ProviderType` is non-empty and one of `qdrant`, `pgvector`, `milvus` (error on unknown).
   - `Collection` is non-empty.
   - `Embedding.ModelID` is non-empty.
6. Return the ordered slice of configs.

### 4d. Update `generateLlamaStackConfig`

Add parameter: `vectorStores []models.ExternalVectorStoreConfig`.

The function processes **Models first**, building all inference providers and registered models. Vector stores are then processed **after** all model providers are built.

**Models phase** (existing logic, unchanged): builds `config.RegisteredResources.Models` from `installModels`.

**Vector stores phase** — when `len(vectorStores) > 0`, for each vector store (index `i`):

1. **Embedding model check**: Look up `store.Embedding.ModelID` in the models already registered in `config.RegisteredResources.Models`. If not found, return a hard error: `"vector store %q requires embedding model %q but it was not included in the install request models"`. The UI is responsible for including the embedding model; this is a programming error if it is absent.
2. **Provider ID**: `vs-<providerType>-<i+1>` (e.g., `vs-qdrant-1`)
3. **VectorIO provider**: build a `Provider` struct with:
   - `ProviderID`: above ID
   - `ProviderType`: `"remote::<store.ProviderType>"`
   - `Config`: copy all fields from `store.Config`, then inject the credential field (if `CredentialSecret` is set) using the env var ref `${env.VS_CREDENTIAL_<i+1>:=}` (use `:=` for optional creds like qdrant/pgvector; omit default for required creds like milvus token).
4. **Registered VectorDB**: build a `VectorDB` struct:
   - `DBID`: `store.Name`
   - `Name`: `store.DisplayName` (or `store.Name` if display name is empty)
   - `ProviderID`: above provider ID
   - `Config`: `{"collection": store.Collection}` plus any extra config fields that belong at the DB level
   - Pass through any other valid fields from the configmap entry

---

## 5. `repositories/llamastack_distribution.go`

Update `InstallLlamaStackDistribution` signature to include `vectorStores []models.InstallVectorStore` and pass it through to `client.InstallLlamaStackDistribution(...)`.

---

## 6. `api/lsd_install_handler.go`

Extract and pass `installRequest.VectorStores` to the repository:

```go
response, err := app.repositories.LlamaStackDistribution.InstallLlamaStackDistribution(
    client, ctx, identity, namespace,
    installRequest.Models,
    installRequest.EnableGuardrails,
    installRequest.VectorStores, // NEW
    maasClient,
)
```

No additional validation needed in the handler — the repository/k8s layer handles errors when vector stores are provided.

---

## 7. `integrations/kubernetes/k8smocks/token_k8s_client_mock.go`

- Add `GetSecret` mock method returning a test secret or an error.
- Update `InstallLlamaStackDistribution` mock signature to add `vectorStores []models.InstallVectorStore`.

---

## 8. Test Updates

### `api/lsd_handler_test.go`

- Update all existing call sites to pass the new param (no-op for existing tests since `VectorStores` will be nil/empty).
- Add new `Describe` block: `LlamaStackDistributionInstallHandlerWithVectorStores`:
  - Test: install with valid vector stores + their embedding models included in `Models` → config includes VectorIO provider + registered VectorDB + env var refs.
  - Test: install with a vector store but embedding model missing from `Models` → 400 bad request with clear message.
  - Test: install with unknown `vector_store_id` → 400 bad request.
  - Test: install with vector store whose credential Secret is missing → 400 bad request.
  - Test: install with vector stores when ConfigMap is absent → 400 bad request.
  - Test: install with empty `vector_stores` → proceeds normally (no vector store config).

### `integrations/kubernetes/llamastack_config_test.go`

- Add tests for `RegisterVectorDB`, `AddExternalVectorStoreProvider`, `CredentialEnvVarField`.

---

## Error Handling Strategy

Per the story AC:

| Scenario | Response |
|---|---|
| `vector_stores` absent/empty | Proceed normally, no error |
| ConfigMap missing | 400: clear message saying ConfigMap not found |
| Store ID not in ConfigMap | 400: `"vector store %q not found"` |
| Invalid/unsupported ProviderType | 400: `"unsupported provider_type %q for vector store %q"` |
| Credential Secret missing | 400: `"secret %q referenced by vector store %q not found"` |
| Embedding model not in request `Models` | 400: `"vector store %q requires embedding model %q but it was not included in the install request models"` |
| LlamaStack install itself fails | Surface generic error + raw error text for diagnostics |

---

## Key Design Decisions

1. **Env var naming**: `VS_CREDENTIAL_<INDEX>` (1-based, ordered by position in the request) — consistent with the `VLLM_API_TOKEN_N` pattern already in use.
2. **All valid configmap fields pass through**: The `Config` map from `ExternalVectorStoreConfig` is merged into the llamastack VectorIO provider config without filtering — this satisfies the AC "allow any valid fields in the configmap to be mapped."
3. **No vector store → no change**: The install path does not touch the vector stores ConfigMap at all when `vector_stores` is absent.
4. **Credential field injection**: Only the credential field gets an env var ref; all other config fields are passed as-is from the ConfigMap.
5. **Embedding model responsibility**: The UI includes the required embedding models in `Models`. The BFF validates they are present after the Models phase and hard-errors if any are missing — no auto-registration.
6. **Models processed before vector stores**: `generateLlamaStackConfig` builds all inference providers and registered models first, then processes vector stores. This ensures the embedding model check has the full set of registered models to validate against.
7. **Credential env var format**: Use `${env.VS_CREDENTIAL_N:=}` (with default empty) for qdrant and pgvector; use `${env.VS_CREDENTIAL_N}` (no default, required) for milvus — matching the patterns shown in the story AC.

---

## Files Changed Summary

| File | Change Type |
|---|---|
| `models/llamastack_distribution.go` | Add `VectorStores []InstallVectorStore` to install request; add `InstallVectorStore` type |
| `integrations/kubernetes/client.go` | Add `GetSecret` to interface; update `InstallLlamaStackDistribution` sig |
| `integrations/kubernetes/llamastack_config.go` | Add `RegisterVectorDB`, `AddExternalVectorStoreProvider`, `CredentialEnvVarField` |
| `integrations/kubernetes/token_k8s_client.go` | Add `GetSecret`; add `loadAndValidateVectorStores`; update install + config generation for vector stores |
| `repositories/llamastack_distribution.go` | Thread `vectorStores []models.InstallVectorStore` through to client |
| `api/lsd_install_handler.go` | Pass `VectorStores` from request to repository |
| `integrations/kubernetes/k8smocks/token_k8s_client_mock.go` | Add `GetSecret` mock; update install mock sig |
| `api/lsd_handler_test.go` | Update existing tests; add new vector store test cases |
| `integrations/kubernetes/llamastack_config_test.go` | Add tests for new config helpers |
