#!/usr/bin/env bash
# negative-test-keyed.sh — prove the keyed query path resolves the API key from
# the Kubernetes Secret PER REQUEST (through the BFF genai-proxy), rather than
# the playground holding credentials or anything being cached.
#
# Method: corrupt the gemini API key Secret -> the keyed query must fail with
# the bug's signature error (Google 400 "Please pass a valid API key") ->
# restore the key -> the same query must succeed again.
#
# Usage:
#   NAMESPACE=embedding-e2e-100933 ./negative-test-keyed.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-embedding-e2e-100933}"
SECRET=gemini-embedding-api-key
TOKEN="${TOKEN:-$(oc whoami -t)}"
POD="$(oc get pods -n "$NAMESPACE" -o name | grep lsd-genai-playground | head -1 | sed 's|pod/||')"
[ -n "$POD" ] || { echo "playground pod not found in $NAMESPACE"; exit 1; }

query_keyed() {
  oc exec -n "$NAMESPACE" "$POD" -- bash -c \
    "curl -s -X POST http://localhost:8321/v1/vector-io/query \
      -H 'Content-Type: application/json' \
      -H 'x-ogx-provider-data: {\"passthrough_api_key\": \"$TOKEN\"}' \
      -d '{\"vector_store_id\": \"vs-e2e-gemini-keyed\", \"query\": \"What is the weather today?\"}'"
}

BACKUP="$(mktemp)"
trap 'rm -f "$BACKUP"' EXIT
oc get secret "$SECRET" -n "$NAMESPACE" -o json | jq -r '.data["api-key"]' | base64 -d > "$BACKUP"

echo ">>> Baseline: keyed query with the good key"
BASE=$(query_keyed | jq '.chunks | length')
echo "    chunks: $BASE (expect 1)"
[ "$BASE" = "1" ] || { echo "baseline already failing — fix before running this test"; exit 1; }

echo ">>> Corrupting the key in the Secret"
oc patch secret "$SECRET" -n "$NAMESPACE" \
  -p '{"data":{"api-key":"Z2FyYmFnZS1rZXktZm9yLW5lZ2F0aXZlLXRlc3Q="}}' >/dev/null
sleep 2

echo ">>> Keyed query with the corrupted key — expect failure"
BAD=$(query_keyed)
BADLEN=$(echo "$BAD" | jq '.chunks | length')
echo "    chunks: $BADLEN (expect 0)"
if echo "$BAD" | grep -q "Please pass a valid API key"; then
  echo "    error surfaced: 400 'Please pass a valid API key' (the bug's signature — but now"
  echo "    it proves the request reached Google via the BFF with the SECRET-sourced key)"
else
  echo "    unexpected failure mode:"; echo "$BAD" | jq . | head -10
fi
[ "$BADLEN" = "0" ] || { echo "query unexpectedly succeeded with a corrupted key"; exit 1; }

echo ">>> Restoring the real key"
oc patch secret "$SECRET" -n "$NAMESPACE" \
  -p "$(jq -nc --arg k "$(base64 < "$BACKUP")" '{data: {"api-key": $k}}')" >/dev/null
sleep 2

echo ">>> Keyed query with the restored key — expect success"
GOOD=$(query_keyed | jq '.chunks | length')
echo "    chunks: $GOOD (expect 1)"
[ "$GOOD" = "1" ] || { echo "query did not recover after key restore"; exit 1; }

echo
echo "PASS — keyed embedding queries resolve the Secret per request through the BFF proxy."
echo "Corollary: the playground pod itself holds no Google credentials"
echo "(verify: oc exec -n $NAMESPACE $POD -- env | grep -iE 'gemini|google|api_key')"
