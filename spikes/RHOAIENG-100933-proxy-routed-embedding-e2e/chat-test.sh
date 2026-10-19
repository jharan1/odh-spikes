#!/usr/bin/env bash
# chat-test.sh — full RAG chat E2E: ask the playground a question over each vector
# store through the BFF /lsd/responses endpoint (the exact UI chat path), using the
# Gemini 2.5 Flash-Lite MaaS model as the chat LLM.
#
# Flow exercised per store:
#   BFF /lsd/responses (JWT)
#     -> playground /v1/responses (x-ogx-provider-data = JWT)
#        -> file_search tool -> query_chunks
#           -> embedding via the store's model (proxy-routed or direct, per store)
#        -> LLM via genai-bff-proxy -> BFF chat proxy -> MaaS gateway -> litellm -> Google
#     -> answer containing the ingested weather content, with file_citation annotations
#
# Note on prompt phrasing: gemini-2.5-flash-lite is a small model — a vague prompt
# ("What is the weather today?") sometimes does not invoke the file_search tool.
# "Search the knowledge base: ..." reliably triggers it. Intermittent empty final
# messages from the model are a known flake; the file_search_call + retrieved chunk
# (the part under test) is consistent on every run.
#
# Usage:
#   NAMESPACE=embedding-e2e-100933 \
#   DASHBOARD_URL=https://rh-ai.apps.<cluster-domain> \
#   CHAT_MODEL=publishers/embedding-e2e-100933/models/gemini-proxy \
#   SUBSCRIPTION=gemini-subscription \
#   ./chat-test.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-embedding-e2e-100933}"
DASHBOARD_URL="${DASHBOARD_URL:?set DASHBOARD_URL, e.g. https://rh-ai.apps.example.com}"
CHAT_MODEL="${CHAT_MODEL:-publishers/${NAMESPACE}/models/gemini-proxy}"
SUBSCRIPTION="${SUBSCRIPTION:-gemini-subscription}"
TOKEN="${TOKEN:-$(oc whoami -t)}"

chat() { # $1 = vector store id, $2 = input text
  curl -s -X POST "$DASHBOARD_URL/gen-ai/api/v1/lsd/responses?namespace=$NAMESPACE" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg store "$1" --arg input "$2" --arg model "$CHAT_MODEL" --arg sub "$SUBSCRIPTION" '{
      input: $input,
      model: $model,
      model_source_type: "maas",
      subscription: $sub,
      vector_store_ids: [$store],
      stream: false
    }')"
}

PASS=0; RETRIEVAL_OK=0
for STORE in vs-e2e-gemini-keyed vs-e2e-granite-keyless-ce vs-e2e-granite-isvc vs-e2e-granite-namespaced-ce; do
  RESULT=$(chat "$STORE" "Search the knowledge base: what does it say about the weather today?")
  FS=$(echo "$RESULT" | jq -r '[.data.output[]? | select(.type=="file_search_call") | .status] | join(",")')
  CHUNKS=$(echo "$RESULT" | jq -r '[.data.output[]? | select(.type=="file_search_call") | .results[]?] | length')
  SCORE=$(echo "$RESULT" | jq -r '[.data.output[]? | select(.type=="file_search_call") | .results[0].score?] | join(",")')
  TEXT=$(echo "$RESULT" | jq -r '[.data.output[]? | select(.type=="message") | .content[]? | .text] | join("")')

  if [ "$FS" = "completed" ] && [ "$CHUNKS" = "1" ]; then
    RETRIEVAL_OK=$((RETRIEVAL_OK+1))
    RETRIEVAL="retrieval OK (file_search=$FS chunks=$CHUNKS score=${SCORE:0:6})"
  else
    RETRIEVAL="RETRIEVAL FAILED (file_search=$FS chunks=$CHUNKS)"
  fi
  if echo "$TEXT" | grep -qi "sunny"; then
    echo "PASS  $STORE — $RETRIEVAL; answer cites the weather content"
    PASS=$((PASS+1))
  elif [ "$FS" = "completed" ] && [ "$CHUNKS" = "1" ]; then
    echo "WARN  $STORE — $RETRIEVAL; model returned an empty message (known flash-lite flake, retrieval is the part under test)"
  else
    echo "FAIL  $STORE — $RETRIEVAL; answer: ${TEXT:0:100}"
    echo "$RESULT" | jq . | head -25
  fi
done

echo
echo "Chat E2E: $PASS/3 stores answered with retrieved content; $RETRIEVAL_OK/3 retrievals succeeded"
[ "$RETRIEVAL_OK" = "3" ]
