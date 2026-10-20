#!/usr/bin/env bash
# agent-chat-test.sh — RAG chat E2E against deployed agent sandboxes (the
# RHOAIENG-101172 verification: static registration of sandbox embedding models).
#
# Each agent serves its own /v1/responses route. The wrapper authenticates the
# caller via a SelfSubjectAccessReview on the Sandbox, injects the file_search
# tool with the agent's vector store, and injects per-request provider data:
#   openai_api_key     — MaaS ephemeral key for the LLM (token exchange)
#   passthrough_api_key — AGENT_EMBEDDING_API_KEY for remote::passthrough
#                        embedding providers (the keyed custom-endpoint agent)
#
# Flow exercised per agent:
#   caller -> agent route /v1/responses (JWT, SSAR-checked)
#     -> file_search -> query_chunks -> embedding via the store's model:
#          agent-keyed-vs       -> agent-embedding-1 (remote::passthrough) -> Google
#                                  with the Secret-sourced API key (deploy-time snapshot)
#          agent-keyless-vs     -> agent-embedding-1 (remote::passthrough) -> ISVC (no auth)
#          agent-isvc-vs        -> agent-embedding-1 (remote::vllm)        -> ISVC direct
#          agent-namespaced-vs  -> agent-embedding-1 (remote::passthrough) -> ISVC
#                                  (model id RedHatAI/granite-embedding-english-r2 verbatim)
#     -> LLM via passthrough-llm (remote::openai) -> MaaS gateway -> gemini-proxy
#   -> answer containing the ingested weather content
#
# Usage:
#   NAMESPACE=embedding-e2e-100933 ./agent-chat-test.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-embedding-e2e-100933}"
QUERY="${QUERY:-Search the knowledge base: what does it say about the weather today?}"
TOKEN="${TOKEN:-$(oc whoami -t)}"

latest_sandbox() { # $1 = agent name prefix -> newest sandbox's route host
  oc get routes -n "$NAMESPACE" -o json \
    | jq -r --arg p "$1" '.items[] | select(.metadata.name | startswith($p)) | "\(.metadata.creationTimestamp)|\(.metadata.name)|https://\(.spec.host)"' \
    | sort | tail -1
}

PASS=0; RETRIEVAL_OK=0
for AGENT in agent-keyed-vs agent-keyless-vs agent-isvc-vs agent-namespaced-vs; do
  LINE="$(latest_sandbox "$AGENT")"
  SANDBOX="${LINE%%|*}"; ROUTE="${LINE##*|}"
  [ -n "$ROUTE" ] || { echo "FAIL  $AGENT — no route found"; continue; }

  RESULT=$(curl -s --max-time 120 -X POST "$ROUTE/v1/responses" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg input "$QUERY" '{input: $input, stream: false}')")

  FS=$(echo "$RESULT" | jq -r '[.output[]? | select(.type=="file_search_call") | .status] | join(",")')
  CHUNKS=$(echo "$RESULT" | jq -r '[.output[]? | select(.type=="file_search_call") | .results[]?] | length')
  SCORE=$(echo "$RESULT" | jq -r '[.output[]? | select(.type=="file_search_call") | .results[0].score?] | join(",")')
  TEXT=$(echo "$RESULT" | jq -r '[.output[]? | select(.type=="message") | .content[]? | .text] | join("")')

  if [ "$FS" = "completed" ] && [ "${CHUNKS:-0}" -ge 1 ]; then
    RETRIEVAL_OK=$((RETRIEVAL_OK+1))
    RETRIEVAL="retrieval OK (file_search=$FS chunks=$CHUNKS score=${SCORE:0:6})"
  else
    RETRIEVAL="RETRIEVAL FAILED (file_search=$FS chunks=$CHUNKS)"
  fi
  if echo "$TEXT" | grep -qi "sunny"; then
    echo "PASS  $AGENT — $RETRIEVAL; answer cites the weather content"
    PASS=$((PASS+1))
  elif [ "$FS" = "completed" ] && [ "$CHUNKS" = "1" ]; then
    echo "WARN  $AGENT — $RETRIEVAL; model returned an empty message (known flash-lite flake, retrieval is the part under test)"
  else
    echo "FAIL  $AGENT — $RETRIEVAL; answer: ${TEXT:0:120}"
    echo "$RESULT" | jq . | head -20
  fi
done

echo
echo ">>> Agent pod log check — 'Failed to search vector store' must be ABSENT:"
TOTAL_ERRORS=0
for AGENT in agent-keyed-vs agent-keyless-vs agent-isvc-vs agent-namespaced-vs; do
  POD=$(oc get pods -n "$NAMESPACE" -o name | grep "^pod/$AGENT" | head -1 | sed 's|pod/||')
  [ -n "$POD" ] || continue
  COUNT=$(oc logs -n "$NAMESPACE" "$POD" 2>&1 | grep -c "Failed to search vector store" || true)
  echo "  $POD: $COUNT"
  TOTAL_ERRORS=$((TOTAL_ERRORS + COUNT))
done

echo
echo "Agent chat E2E: $PASS/4 agents answered with retrieved content; $RETRIEVAL_OK/4 retrievals succeeded; $TOTAL_ERRORS search errors logged"
[ "$RETRIEVAL_OK" = "4" ] && [ "$TOTAL_ERRORS" = "0" ]
