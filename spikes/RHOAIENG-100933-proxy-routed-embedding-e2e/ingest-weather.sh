#!/usr/bin/env bash
# ingest-weather.sh — insert the weather test chunk into each of the four stores.
#
# External vector stores are query-only in the current UX (uploads go to the
# auto-provisioned store with the inline default embedding model), so test data
# is inserted directly through the playground's /v1/vector-io/insert endpoint
# with PRE-COMPUTED embeddings:
#
#   - the Gemini embedding (3072 dims) is computed directly against Google's
#     OpenAI-compatible endpoint using the API key from the Secret
#   - the granite embedding (768 dims) is computed against the ISVC
#     (the same vLLM model serves granite-embedding-r2, granite-embedding-keyless
#     and RedHatAI/granite-embedding-english-r2, so one embedding covers all
#     three granite stores)
#
# The insert payload is an OGX EmbeddedChunk: the same shape the file_search
# ingestion path writes (see ogx providers/remote/vector_io/pgvector — table
# per store: vs_<vector_store_id with dashes replaced by underscores>).
#
# Usage:
#   NAMESPACE=embedding-e2e-100933 ./ingest-weather.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-embedding-e2e-100933}"
POD="$(oc get pods -n "$NAMESPACE" -o name | grep lsd-genai-playground | head -1 | sed 's|pod/||')"
[ -n "$POD" ] || { echo "playground pod not found in $NAMESPACE"; exit 1; }
ISVC_POD="$(oc get pods -n "$NAMESPACE" -o name | grep granite-embedding-r2-predictor | grep -v Crash | head -1 | sed 's|pod/||')"
[ -n "$ISVC_POD" ] || { echo "granite ISVC pod not found in $NAMESPACE"; exit 1; }
KEY="$(oc get secret gemini-embedding-api-key -n "$NAMESPACE" -o jsonpath='{.data.api-key}' | base64 -d)"

WEATHER="Today's weather is sunny with a high of 25 degrees Celsius and a low of 15 degrees. There is only a 10 percent chance of rain."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ">>> Computing Gemini embedding (3072 dims)"
jq -nc --arg t "$WEATHER" '{model: "gemini-embedding-001", input: $t}' \
  | curl -s -X POST "https://generativelanguage.googleapis.com/v1beta/openai/v1/embeddings" \
      -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d @- > "$WORK/gemini.json"
DIMS=$(jq '.data[0].embedding | length' "$WORK/gemini.json")
[ "$DIMS" = "3072" ] || { echo "unexpected gemini dims: $DIMS"; exit 1; }

echo ">>> Computing granite embedding (768 dims) via the ISVC"
oc exec -n "$NAMESPACE" "$ISVC_POD" -c kserve-container -- \
  curl -s http://localhost:8080/v1/embeddings -H "Content-Type: application/json" \
  -d "$(jq -nc --arg t "$WEATHER" '{model: "granite-embedding-r2", input: $t}')" > "$WORK/granite.json"
DIMS=$(jq '.data[0].embedding | length' "$WORK/granite.json")
[ "$DIMS" = "768" ] || { echo "unexpected granite dims: $DIMS"; exit 1; }

echo ">>> Building insert payloads"
# Qualified embedding model per store, read from the GENERATED llama-stack-config
# (the vllm-inference-N suffix depends on the install model list position, so
# don't hardcode it).
qualified() { # $1 = vector_store_id -> embedding_model from llama-stack-config
  oc get cm llama-stack-config -n "$NAMESPACE" -o jsonpath='{.data.config\.yaml}' \
    | grep -A1 "vector_store_id: $1" | grep 'embedding_model:' | awk '{print $2}'
}
make_payload() { # $1=store $2=embedding-file $3=qualified-model $4=dim
  jq -nc --arg content "$WEATHER" --slurpfile emb "$2" '{
    vector_store_id: $store,
    chunks: [{
      content: $content,
      chunk_id: "weather-chunk-001",
      metadata: {document_id: "weather-doc-001", source: "weather.txt"},
      chunk_metadata: {chunk_id: "weather-chunk-001", document_id: "weather-doc-001", source: "weather.txt"},
      embedding: $emb[0].data[0].embedding,
      embedding_model: $model,
      embedding_dimension: $dim
    }]
  }' --arg store "$1" --arg model "$3" --argjson dim "$4"
}
make_payload vs-e2e-gemini-keyed       "$WORK/gemini.json"  "$(qualified vs-e2e-gemini-keyed)"       3072 > "$WORK/ins-gemini.json"
make_payload vs-e2e-granite-keyless-ce "$WORK/granite.json" "$(qualified vs-e2e-granite-keyless-ce)" 768 > "$WORK/ins-ce.json"
make_payload vs-e2e-granite-isvc       "$WORK/granite.json" "$(qualified vs-e2e-granite-isvc)"       768 > "$WORK/ins-isvc.json"
make_payload vs-e2e-granite-namespaced-ce "$WORK/granite.json" "$(qualified vs-e2e-granite-namespaced-ce)" 768 > "$WORK/ins-ns.json"

echo ">>> Inserting into the playground ($POD)"
for f in ins-gemini ins-ce ins-isvc ins-ns; do
  oc cp "$WORK/$f.json" "$NAMESPACE/$POD:/tmp/$f.json"
  CODE=$(oc exec -n "$NAMESPACE" "$POD" -- curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://localhost:8321/v1/vector-io/insert \
    -H "Content-Type: application/json" -d @/tmp/$f.json)
  echo "  $f -> HTTP $CODE (204 = inserted)"
  [ "$CODE" = "204" ] || exit 1
done

echo ">>> Row counts in pgvector (table per store: vs_<id, dashes->underscores>)"
oc exec -n "$NAMESPACE" deployment/genai-pgvector -- psql -U vectoruser -d vectordb -t -c \
  "SELECT 'gemini_keyed: '  || count(*) FROM vs_vs_e2e_gemini_keyed
     UNION ALL SELECT 'granite_ce: '   || count(*) FROM vs_vs_e2e_granite_keyless_ce
     UNION ALL SELECT 'granite_isvc: ' || count(*) FROM vs_vs_e2e_granite_isvc
     UNION ALL SELECT 'granite_ns_ce: ' || count(*) FROM vs_vs_e2e_granite_namespaced_ce"
echo "Expected: 1 row in each"
