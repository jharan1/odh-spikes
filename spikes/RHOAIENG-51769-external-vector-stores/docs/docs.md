# External Vector Stores in the Gen AI Playground

External vector stores let you surface pre-populated vector databases—PGVector, Qdrant, or Milvus—as selectable knowledge sources for RAG in the Gen AI Playground.

---

## Prerequisites

- A vector database of one of the supported types is running and reachable from the cluster:
  - PGVector (`remote::pgvector`)
  - Qdrant (`remote::qdrant`)
  - Milvus (`remote::milvus`)
- The vector store (collection) is pre-populated with embeddings.
- You know the embedding model that was used to generate the stored embeddings. A custom model endpoint for that same model must be registered in the project (with the exception of `ibm-granite/granite-embedding-125m-english` model, which is available by default in the Llamastack instance).
- The `externalVectorStores` feature flag is set to `true` in the `OdhDashboardConfig` CR. Contact your cluster administrator if external vector stores are not visible in the UI.

---

## Procedure

### Step 1 — Create Secrets for database credentials (if required)

If your vector database requires authentication, a cluster or namespace administrator must create a Kubernetes Secret in the project namespace. These credentials are injected into the LlamaStack configuration at install time.

**PGVector example**
```bash
oc create secret generic pgvector-credentials -n <your-project> \
  --from-literal=password=<your-pgvector-password>
```

**Qdrant example**
```bash
oc create secret generic qdrant-credentials -n <your-project> \
  --from-literal=api_key=<your-qdrant-api-key>
```

**Milvus example**
```bash
oc create secret generic milvus-credentials -n <your-project> \
  --from-literal=token=<your-milvus-token>
```

### Step 2 — Create the `gen-ai-aa-vector-stores` ConfigMap

A cluster or namespace administrator must create a ConfigMap named exactly `gen-ai-aa-vector-stores` in the same project namespace as the Llamastack playground will be installed. The ConfigMap has a single data key `config.yaml` with two top-level sections:

- `providers.vector_io` — connection details for each vector database
- `registered_resources.vector_stores` — one entry per vector store collection or table

> **Important:** Multiple vector stores can reference the same provider (for example, two separate PGVector tables in the same database). Each vector store entry must have a unique `vector_store_id`.

**Example ConfigMap with PGVector, Milvus (no credentials), Milvus (with token), and Qdrant**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gen-ai-aa-vector-stores
  namespace: <your-project>
data:
  config.yaml: |
    providers:
      vector_io:

        # PGVector provider — requires password from a Secret
        - provider_id: pgvector-prod
          provider_type: remote::pgvector
          config:
            host: pgvector.databases.svc.cluster.local
            port: 5432
            db: vectordb
            user: vectoruser
            distance_metric: COSINE    # Optional. One of: COSINE, L2, L1, INNER_PRODUCT
            custom_gen_ai:
              credentials:
                secretRefs:
                  - name: pgvector-credentials   # Name of the Secret created in Step 1
                    key: password                # Key within the Secret

        # Milvus provider — no authentication required
        - provider_id: milvus-public
          provider_type: remote::milvus
          config:
            uri: http://milvus.my-project.svc.cluster.local:19530

        # Milvus provider — token authentication
        - provider_id: milvus-secure
          provider_type: remote::milvus
          config:
            uri: https://secure-hosted-milvus.com
            custom_gen_ai:
              credentials:
                secretRefs:
                  - name: milvus-credentials
                    key: token

        # Qdrant provider — API key authentication
        - provider_id: qdrant-prod
          provider_type: remote::qdrant
          config:
            url: http://qdrant.my-project.svc.cluster.local
            port: 6333
            custom_gen_ai:
              credentials:
                secretRefs:
                  - name: qdrant-credentials
                    key: api_key

    registered_resources:
      vector_stores:

        # Two collections backed by the same PGVector provider
        - provider_id: pgvector-prod
          vector_store_id: vs_282695f8-7e3e-48da-abac-d81a0aa225a4   # the vector store collection ID
          embedding_model: ibm-granite/granite-embedding-125m-english
          embedding_dimension: 768
          vector_store_name: "Product Documentation"
          metadata:
            description: "Product documentation embeddings for customer support RAG"

        - provider_id: pgvector-prod
          vector_store_id: vs_50f14ad3-6cf4-466b-a7b6-8b01afcc1e47
          embedding_model: ibm-granite/granite-embedding-125m-english
          embedding_dimension: 768
          vector_store_name: "Legal Contracts"
          metadata:
            description: "Legal contract search for the compliance team"

        # Milvus collections
        - provider_id: milvus-public
          vector_store_id: vs_4c4b74e3-30ac-4e46-9057-213154f83dba
          embedding_model: ibm-granite/granite-embedding-125m-english
          embedding_dimension: 768
          vector_store_name: "Enterprise Search"
          metadata:
            description: "Company-wide knowledge base"

        - provider_id: milvus-secure
          vector_store_id: vs_a2607363-cea0-4d2a-8a93-7fb76863403b
          embedding_model: ibm-granite/granite-embedding-125m-english
          embedding_dimension: 768
          vector_store_name: "Internal Knowledge Base"
          metadata:
            description: "Secure internal research knowledge base"

        # Qdrant collection
        - provider_id: qdrant-prod
          vector_store_id: vs_3fa896ef-5e25-4935-baeb-adf9ac59cb6d
          embedding_model: ibm-granite/granite-embedding-125m-english
          embedding_dimension: 768
          vector_store_name: "Support Knowledge Base"
```

#### ConfigMap field reference

| Field | Required | Description |
|---|---|---|
| `provider_id` | Yes | Unique identifier for the provider. Referenced by `registered_resources.vector_stores[].provider_id`. |
| `provider_type` | Yes | One of `remote::pgvector`, `remote::qdrant`, `remote::milvus`. |
| `config` | Yes | Provider-specific connection settings. See provider reference tables below. |
| `custom_gen_ai.credentials.secretRefs` | No | List of `{name, key}` references to Kubernetes Secrets holding credentials. Omit entirely if no authentication is required. |
| `vector_store_id` | Yes | A unique identifier for this collection or table. Must not change after the LSD is installed—LlamaStack persists this ID internally. |
| `vector_store_name` | Yes | Display name shown in the UI. |
| `embedding_model` | Yes | The model identifier (provider_model_id) used when the data was embedded. Must match an available custom model endpoint or InferenceService in the namespace. |
| `embedding_dimension` | Yes | Dimension of the embedding vectors (for example, `768`). |
| `metadata.description` | No | Human-readable description shown in the AI Assets vector stores table. |

#### Provider connection reference

**PGVector (`remote::pgvector`)**

| Field | Required | Description |
|---|---|---|
| `host` | Yes | Hostname or Kubernetes service name of the PostgreSQL instance. |
| `port` | Yes | PostgreSQL port (typically `5432`). |
| `db` | Yes | Database name. |
| `user` | No | Database user (if authentication is required alongside the password Secret). |
| `distance_metric` | No | One of `COSINE` (default), `L2`, `L1`, `INNER_PRODUCT`. |

**Qdrant (`remote::qdrant`)**

| Field | Required | Description |
|---|---|---|
| `url` | Yes | Base URL of the Qdrant REST API. |
| `port` | No | REST port (default `6333`). |
| `grpc_port` | No | gRPC port (default `6334`). |
| `prefer_grpc` | No | Use gRPC instead of REST (`true`/`false`). |

**Milvus (`remote::milvus`)**

| Field | Required | Description |
|---|---|---|
| `uri` | Yes | Full URI of the Milvus endpoint (for example, `http://milvus.svc.cluster.local:19530`). |

### Step 3 — Install the Playground with the vector store

1. From the dashboard, click **Gen AI studio** → **AI asset endpoints**, then select the **Vector Stores** tab.
2. The table lists all vector store collections defined in the `gen-ai-aa-vector-stores` ConfigMap. Vector stores whose embedding model is not yet available in the namespace are shown as **Not available** and cannot be selected.
3. Click **Add to playground** next to the vector store collection you want to use.
4. In the **Configure Playground** modal, confirm the vector store selection. Adjust the model selection if needed, then click **Configure**.
5. Wait for the Playground to finish installing. If installation fails with a vector store error, check the error message and verify the ConfigMap and credentials are correct.

### Step 4 — Enable the vector store in the Playground

1. From the dashboard, click **Gen AI Studio** → **Playground**.
2. In the **Playground** interface, click the **Knowledge** tab.
3. Select **Use an existing vector store**.
4. From the dropdown, select the vector store to use. Click the **Toggle RAG mode** switch to enable the vector store to be used in the chat.
5. In the chat input field, ask a question related to the content indexed in the vector store.

The model retrieves relevant context from the selected vector store and uses it to generate a grounded response.

---

## Verification

- The model response references information from the vector store rather than relying solely on its pre-trained knowledge.
- If you ask a question outside the scope of the indexed content, the model indicates that relevant information was not found, or falls back to its general knowledge.
- In the **AI Assets** → **Vector Stores** tab, the status of the vector store you selected shows as **Registered**.
