# External Vector Stores in the Gen AI Playground

External vector stores let you surface pre-populated vector databases—PGVector, Qdrant, or Milvus—as selectable knowledge sources for RAG in the Gen AI Playground. Platform engineers register vector stores by creating a ConfigMap in the project namespace; AI engineers then select a vector store from the **Knowledge** tab or the **AI Assets** page without ever seeing database credentials or connection details.

> **Note:** In RHOAI 3.4, you can enable one external vector store per chat pane. Document upload and ingestion into external vector stores are not supported through the Playground; data must be pre-populated through external pipelines or tools before registration.

---

## For Platform Engineers/Admins: Registering External Vector Stores

### Prerequisites

- You have cluster administrator or namespace administrator access to the target project.
- A vector database of one of the supported types is running and reachable from the cluster:
  - PGVector (`remote::pgvector`)
  - Qdrant (`remote::qdrant`)
  - Milvus (`remote::milvus`)
- The vector store (collection) is pre-populated with embeddings. The Gen AI Playground does not ingest or re-index data.
- You know the embedding model that was used to generate the stored embeddings. An InferenceService or custom model endpoint for that same model must be registered in the project.
- The `disableExternalVectorStores` feature flag is set to `false` (or omitted) in the `OdhDashboardConfig` CR. Contact your cluster administrator if external vector stores are not visible to AI engineers.

### Step 1 — Create Secrets for database credentials (if required)

If your vector database requires authentication, create a Kubernetes Secret in the same namespace as the project. The BFF reads these secrets at install time to inject credentials into the LlamaStack configuration; credentials are never sent to the browser.

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

Create a ConfigMap named exactly `gen-ai-aa-vector-stores` in the project namespace. The ConfigMap has a single data key `config.yaml` with two top-level sections:

- `providers.vector_io` — connection details for each vector database (never exposed to the frontend)
- `registered_resources.vector_stores` — one entry per collection or table that AI engineers can select

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
                    key: password                 # Key within the Secret

        # Milvus provider — no authentication required
        - provider_id: milvus-public
          provider_type: remote::milvus
          config:
            uri: http://milvus.my-project.svc.cluster.local:19530

        # Milvus provider — token authentication
        - provider_id: milvus-secure
          provider_type: remote::milvus
          config:
            uri: http://milvus-secure.my-project.svc.cluster.local:19530
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

### Step 3 — Install/Reinstall the LlamaStack Distribution

1. Ensure the `externalVectorStores` feature flag is enabled.
2. From the dashboard, click **Gen AI studio** → **AI asset endpoints**, then select the **Vector Stores** tab.
3. In this tab you can view the vector stores defined in the `gen-ai-aa-vector-stores` ConfigMap, and identify which vector stores can be selected for install.
4. If the **Add to playground** link is enabled for a vector store, click it to open the **Configure Playground** modal. In the modal, select the vector store you want to install. If you need to change the models selected, you can do that on the first page of the modal. Click **Configure** to install the playground with the selected model(s) and vector store(s).

---

### Step 4 — Using External Vector Stores in the Gen-AI Playground

### Prerequisites

- A platform engineer has created the `gen-ai-aa-vector-stores` ConfigMap in your project namespace.
- The playground has been installed with the vector store(s) you want to use.
- The `externalVectorStores` feature flag is enabled.

### Procedure

1. From the dashboard, click **Gen AI Studio** → **Playground**.
2. In the **Playground** interface, click the **Knowledge** tab.
3. Select **External vector store**.
4. From the dropdown, select the vector store to use for this chat session. Click the "Toggle RAG mode" switch to enable the Knowledge feature.
5. In the chat input field, ask a question related to the content indexed in the vector store.

The model retrieves relevant context from the selected vector store and uses it to generate a grounded response.

### Verification

- The model response references information from the vector store rather than relying solely on its pre-trained knowledge.
- If you ask a question outside the scope of the indexed content, the model indicates that relevant information was not found, or falls back to its general knowledge.
- In the **AI Assets** → **Vector Stores** tab, the status of the vector store you selected shows as **Registered**.
- If the Playground fails to install after selecting a vector store, check the error message displayed in the UI for details about the misconfigured store. Pass this information to your platform engineer.
