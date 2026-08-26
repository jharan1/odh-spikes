"""Insert weather data directly into pgvector with pre-computed embeddings.

Usage:
    python3 ingest_weather.py <embedding_vector> <pg_pod_name>

Why direct insert instead of the LlamaStack file ingestion API?
LlamaStack's POST /v1/vector_stores/{id}/files spawns an async background task for chunking
and embedding. The remote::passthrough provider reads its API key from the
X-LlamaStack-Provider-Data request header, but that header is gone by the time the background
task runs — causing ValueError. Pre-computing the embedding externally and inserting directly
into pgvector bypasses this limitation.
"""

import json
import subprocess
import sys
import time
import uuid

weather_text = "Today's weather is sunny with a high of 25C and a low of 15C. There is a 10% chance of rain."
vs_table = "vs_vs_bff00003_0000_0000_0000_000000000001"
chunk_id = str(uuid.uuid4())
file_id = "file-weather-direct-insert"
now = int(time.time())
embedding = sys.argv[1]
pg_pod = sys.argv[2]

doc = {
    "content": weather_text,
    "chunk_id": chunk_id,
    "metadata": {
        "file_id": file_id, "chunk_id": chunk_id, "filename": "weather.txt",
        "document_id": file_id, "token_count": 20,
        "chunk_tokenizer": "tiktoken:cl100k_base", "metadata_token_count": 10
    },
    "chunk_metadata": {
        "source": None, "chunk_id": chunk_id, "document_id": file_id,
        "chunk_window": "0-20", "chunk_tokenizer": "tiktoken:cl100k_base",
        "created_timestamp": now, "updated_timestamp": now,
        "content_token_count": 20, "metadata_token_count": 10
    },
    "embedding_model": "RedHatAI/granite-embedding-english-r2",
    "embedding_dimension": 768
}

doc_json = json.dumps(doc).replace("'", "''")
safe_text = weather_text.replace("'", "''")

sql = f"""INSERT INTO {vs_table} (id, document, embedding, content_text, tokenized_content)
VALUES ('{chunk_id}', '{doc_json}'::jsonb, '{embedding}'::vector, '{safe_text}', to_tsvector('english', '{safe_text}'));"""

result = subprocess.run(
    ["oc", "exec", "-n", "pgvect", pg_pod, "--", "psql", "-U", "vectoruser", "-d", "vectordb", "-c", sql],
    capture_output=True, text=True
)
print(result.stdout)
if result.stderr:
    print("STDERR:", result.stderr)
sys.exit(result.returncode)
