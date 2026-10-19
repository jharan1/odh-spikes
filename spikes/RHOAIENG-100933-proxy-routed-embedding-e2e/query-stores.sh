#!/usr/bin/env bash
# query-stores.sh — query each store the same way the file_search tool does at
# query time, and check the playground logs for the bug's signature error.
#
# The query goes to the playground's POST /v1/vector-io/query (the exact code
# path file_search uses inside /v1/responses). The x-ogx-provider-data header
# carries the user JWT — identical to what the BFF's getProviderData injects —
# which the genai-bff-proxy passthrough provider forwards as
# passthrough_api_key to authenticate to the BFF genai-proxy.
#
# Per-store expected flow:
#   vs-e2e-gemini-keyed        playground -> genai-bff-proxy -> BFF -> Google (Secret-sourced API key)
#   vs-e2e-granite-keyless-ce  playground -> genai-bff-proxy -> BFF -> ISVC  (no auth header)
#   vs-e2e-granite-isvc        playground -> vllm-inference-3 -> ISVC direct (no BFF, no regression)
#
# Usage:
#   NAMESPACE=embedding-e2e-100933 QUERY="What is the weather today?" ./query-stores.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-embedding-e2e-100933}"
QUERY="${QUERY:-What is the weather today?}"
TOKEN="${TOKEN:-$(oc whoami -t)}"
POD="$(oc get pods -n "$NAMESPACE" -o name | grep lsd-genai-playground | head -1 | sed 's|pod/||')"
[ -n "$POD" ] || { echo "playground pod not found in $NAMESPACE"; exit 1; }

PASS=0; FAIL=0
for STORE in vs-e2e-gemini-keyed vs-e2e-granite-keyless-ce vs-e2e-granite-isvc; do
  RESULT=$(oc exec -n "$NAMESPACE" "$POD" -- bash -c \
    "curl -s -X POST http://localhost:8321/v1/vector-io/query \
      -H 'Content-Type: application/json' \
      -H 'x-ogx-provider-data: {\"passthrough_api_key\": \"$TOKEN\"}' \
      -d '{\"vector_store_id\": \"$STORE\", \"query\": \"$QUERY\"}'")
  NUM=$(echo "$RESULT" | jq '.chunks | length')
  CONTENT=$(echo "$RESULT" | jq -r '.chunks[0].content // empty' | head -c 60)
  if [ "$NUM" = "1" ] && echo "$CONTENT" | grep -qi "weather"; then
    echo "PASS  $STORE — $NUM chunk: \"$CONTENT...\""
    PASS=$((PASS+1))
  else
    echo "FAIL  $STORE — num_chunks=$NUM content=$CONTENT"
    echo "$RESULT" | jq . | head -20
    FAIL=$((FAIL+1))
  fi
done

echo
echo ">>> Playground log check — 'Failed to search vector store' must be ABSENT:"
oc logs -n "$NAMESPACE" "$POD" 2>&1 | grep -c "Failed to search vector store" || true

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
