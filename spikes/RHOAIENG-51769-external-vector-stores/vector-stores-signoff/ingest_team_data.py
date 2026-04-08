"""
Ingest team data into pgvector, qdrant, and/or milvus vector stores for vector-stores-signoff namespace.

Usage:
    python3 ingest_team_data.py <openai_api_key> <pg_pod> [options]

Options:
  --stores pgvector qdrant milvus   Which stores to ingest into (default: all three)
  --llamastack-url URL              LlamaStack API URL for milvus ingestion
                                    (default: http://localhost:8321)

Examples:
  # Ingest all stores
  python3 ingest_team_data.py "$OPENAI_KEY" "$PG_POD"

  # Ingest milvus only (requires port-forward)
  python3 ingest_team_data.py "$OPENAI_KEY" "$PG_POD" --stores milvus

  # Ingest pgvector and qdrant only
  python3 ingest_team_data.py "$OPENAI_KEY" "$PG_POD" --stores pgvector qdrant

For milvus ingestion, port-forward the LlamaStack service first:
  oc port-forward svc/lsd-genai-playground 8321:8321 -n vector-stores-signoff
"""
import argparse
import hashlib
import json
import subprocess
import sys
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser(description="Ingest team data into vector stores")
parser.add_argument("openai_api_key", help="OpenAI API key")
parser.add_argument("pg_pod", help="pgvector pod name in the pgvect namespace")
parser.add_argument(
    "--stores",
    nargs="+",
    choices=["pgvector", "qdrant", "milvus"],
    default=["pgvector", "qdrant", "milvus"],
    metavar="STORE",
    help="Stores to ingest into: pgvector, qdrant, milvus (default: all)",
)
parser.add_argument(
    "--llamastack-url",
    default="http://localhost:8321",
    help="LlamaStack API URL for milvus ingestion (default: http://localhost:8321)",
)
args = parser.parse_args()

OPENAI_API_KEY = args.openai_api_key
PG_POD         = args.pg_pod
LLAMASTACK_URL = args.llamastack_url
STORES         = set(args.stores)

PGVECTOR_TEXT = "Scrum team: JohnP, JaneP, FredP, JoeP"
QDRANT_TEXT   = "Scrum team: JohnQ, JaneQ, FredQ, JoeQ"
MILVUS_TEXT   = "Scrum team: JohnM, JaneM, FredM, JoeM"

PGVECTOR_VS_TABLE = "vs_vs_signoff_pgvector_001"
QDRANT_VS_ID      = "vs_signoff-qdrant-001"
MILVUS_VS_ID      = "vs_signoff-milvus-001"
QDRANT_HOST       = "qdrant.qdrant.svc.cluster.local"
QDRANT_PORT       = 6333
EMBEDDING_MODEL   = "text-embedding-3-small"
EMBEDDING_DIM     = 1536


def get_embedding(text):
    data = json.dumps({"model": EMBEDDING_MODEL, "input": [text]}).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/embeddings",
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {OPENAI_API_KEY}",
        },
        method="POST",
    )
    resp = urllib.request.urlopen(req)
    result = json.loads(resp.read())
    return result["data"][0]["embedding"]


def insert_pgvector(text, embedding):
    chunk_id = str(uuid.uuid4())
    file_id = "file-team-pgvector"
    now = int(time.time())
    doc = {
        "content": text,
        "chunk_id": chunk_id,
        "metadata": {
            "file_id": file_id, "chunk_id": chunk_id, "filename": "team-pgvector.txt",
            "document_id": file_id, "token_count": 10,
            "chunk_tokenizer": "tiktoken:cl100k_base", "metadata_token_count": 5,
        },
        "chunk_metadata": {
            "source": None, "chunk_id": chunk_id, "document_id": file_id,
            "chunk_window": "0-10", "chunk_tokenizer": "tiktoken:cl100k_base",
            "created_timestamp": now, "updated_timestamp": now,
            "content_token_count": 10, "metadata_token_count": 5,
        },
        "embedding_model": f"openai-provider/{EMBEDDING_MODEL}",
        "embedding_dimension": EMBEDDING_DIM,
    }
    doc_json = json.dumps(doc).replace("'", "''")
    safe_text = text.replace("'", "''")
    embedding_str = "[" + ",".join(map(str, embedding)) + "]"
    sql = (
        f"INSERT INTO {PGVECTOR_VS_TABLE} (id, document, embedding, content_text, tokenized_content) "
        f"VALUES ('{chunk_id}', '{doc_json}'::jsonb, '{embedding_str}'::vector, "
        f"'{safe_text}', to_tsvector('english', '{safe_text}'));"
    )
    result = subprocess.run(
        ["oc", "exec", "-n", "pgvect", PG_POD, "--", "psql", "-U", "vectoruser", "-d", "vectordb", "-c", sql],
        capture_output=True, text=True,
    )
    print(result.stdout)
    if result.stderr:
        print("STDERR:", result.stderr)
    return result.returncode


def qdrant_request(method, path, body=None, pod_name="qdrant-op"):
    """Run a qdrant REST API call from within the cluster via a temporary curl pod."""
    cmd = [
        "oc", "run", "-n", "qdrant", pod_name, "--image=curlimages/curl",
        "--restart=Never", "--rm", "-i", "--",
        "curl", "-s", "-X", method,
        f"http://{QDRANT_HOST}:{QDRANT_PORT}{path}",
        "-H", "Content-Type: application/json",
    ]
    if body:
        cmd += ["-d", body]
    result = subprocess.run(cmd, capture_output=True, text=True)
    # Strip any trailing oc housekeeping messages (e.g. 'pod "x" deleted') after the JSON
    stdout = result.stdout
    last_brace = stdout.rfind("}")
    if last_brace != -1:
        stdout = stdout[: last_brace + 1]
    return stdout, result.returncode


def ensure_qdrant_collection():
    """Create the qdrant collection if it doesn't already exist."""
    print(f"Checking qdrant collection '{QDRANT_VS_ID}'...")
    out, _ = qdrant_request("GET", f"/collections/{QDRANT_VS_ID}", pod_name="qdrant-check")
    response = json.loads(out)
    if response.get("status") == "ok":
        print("Collection already exists.")
        return
    print("Collection not found — creating...")
    body = json.dumps({"vectors": {"size": EMBEDDING_DIM, "distance": "Cosine"}})
    out, rc = qdrant_request("PUT", f"/collections/{QDRANT_VS_ID}", body=body, pod_name="qdrant-create")
    print(out)
    if rc != 0 or '"ok"' not in out:
        print("Failed to create qdrant collection")
        sys.exit(1)
    print("Collection created.")


def convert_qdrant_id(chunk_id):
    """Mirrors LlamaStack's convert_id — SHA-256 hash of 'qdrant_id:<chunk_id>', formatted as UUID."""
    hash_input = f"qdrant_id:{chunk_id}".encode()
    sha256_hash = hashlib.sha256(hash_input).hexdigest()
    return f"{sha256_hash[:8]}-{sha256_hash[8:12]}-{sha256_hash[12:16]}-{sha256_hash[16:20]}-{sha256_hash[20:32]}"


def insert_qdrant(text, embedding):
    """Insert a point into qdrant with the payload structure LlamaStack expects."""
    chunk_id = str(uuid.uuid4())
    file_id = "file-team-qdrant"
    now = int(time.time())
    chunk_content = {
        "content": text,
        "chunk_id": chunk_id,
        "metadata": {
            "file_id": file_id, "chunk_id": chunk_id, "filename": "team-qdrant.txt",
            "document_id": file_id, "token_count": 10,
            "chunk_tokenizer": "tiktoken:cl100k_base", "metadata_token_count": 5,
        },
        "chunk_metadata": {
            "source": None, "chunk_id": chunk_id, "document_id": file_id,
            "chunk_window": "0-10", "chunk_tokenizer": "tiktoken:cl100k_base",
            "created_timestamp": now, "updated_timestamp": now,
            "content_token_count": 10, "metadata_token_count": 5,
        },
        "embedding_model": f"openai-provider/{EMBEDDING_MODEL}",
        "embedding_dimension": EMBEDDING_DIM,
        "embedding": embedding,
    }
    point_id = convert_qdrant_id(chunk_id)
    payload = json.dumps({
        "points": [{
            "id": point_id,
            "vector": embedding,
            "payload": {
                "chunk_content": chunk_content,
                "content_text": text,
                "_chunk_id": chunk_id,
            },
        }]
    })
    out, rc = qdrant_request("PUT", f"/collections/{QDRANT_VS_ID}/points", body=payload, pod_name="qdrant-insert")
    print(out)
    if rc != 0:
        print("FAILED")
    return rc


def insert_milvus(text, embedding):
    """Insert a pre-embedded chunk into milvus via the LlamaStack vector-io API.

    Requires the LlamaStack service to be accessible at LLAMASTACK_URL.
    Use oc port-forward to expose it locally before running.
    """
    chunk_id = str(uuid.uuid4())
    file_id = "file-team-milvus"
    now = int(time.time())
    chunk = {
        "content": text,
        "chunk_id": chunk_id,
        "metadata": {
            "file_id": file_id, "chunk_id": chunk_id, "filename": "team-milvus.txt",
            "document_id": file_id, "token_count": 10,
            "chunk_tokenizer": "tiktoken:cl100k_base", "metadata_token_count": 5,
        },
        "chunk_metadata": {
            "source": None, "chunk_id": chunk_id, "document_id": file_id,
            "chunk_window": "0-10", "chunk_tokenizer": "tiktoken:cl100k_base",
            "created_timestamp": now, "updated_timestamp": now,
            "content_token_count": 10, "metadata_token_count": 5,
        },
        "embedding_model": f"openai-provider/{EMBEDDING_MODEL}",
        "embedding_dimension": EMBEDDING_DIM,
        "embedding": embedding,
    }
    data = json.dumps({
        "vector_store_id": MILVUS_VS_ID,
        "chunks": [chunk],
    }).encode()
    req = urllib.request.Request(
        f"{LLAMASTACK_URL}/v1/vector-io/insert",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    resp = urllib.request.urlopen(req)
    return resp.status


# --- Compute embeddings only for stores that need them ---

embedding_p = embedding_q = None

if "pgvector" in STORES or "qdrant" in STORES:
    print("=== Computing embeddings via OpenAI ===")

if "pgvector" in STORES:
    print(f"pgvector text: {PGVECTOR_TEXT}")
    embedding_p = get_embedding(PGVECTOR_TEXT)
    print(f"Got embedding, dim={len(embedding_p)}")

if "qdrant" in STORES:
    print(f"qdrant text: {QDRANT_TEXT}")
    embedding_q = get_embedding(QDRANT_TEXT)
    print(f"Got embedding, dim={len(embedding_q)}")

# --- Insert ---

if "pgvector" in STORES:
    print("\n=== Inserting into pgvector ===")
    rc = insert_pgvector(PGVECTOR_TEXT, embedding_p)
    if rc == 0:
        print("pgvector insert OK")
    else:
        print("pgvector insert FAILED")
        sys.exit(rc)

if "qdrant" in STORES:
    print("\n=== Inserting into qdrant ===")
    ensure_qdrant_collection()
    rc = insert_qdrant(QDRANT_TEXT, embedding_q)
    if rc == 0:
        print("qdrant insert OK")
    else:
        print("qdrant insert FAILED")
        sys.exit(rc)

if "milvus" in STORES:
    print("\n=== Inserting into milvus (via LlamaStack API) ===")
    print(f"LlamaStack URL: {LLAMASTACK_URL}")
    print(f"milvus text: {MILVUS_TEXT}")
    embedding_m = get_embedding(MILVUS_TEXT)
    print(f"Got embedding, dim={len(embedding_m)}")
    status = insert_milvus(MILVUS_TEXT, embedding_m)
    if status in (200, 204):
        print("milvus insert OK")
    else:
        print(f"milvus insert FAILED (status {status})")
        sys.exit(1)

print("\nDone.")
