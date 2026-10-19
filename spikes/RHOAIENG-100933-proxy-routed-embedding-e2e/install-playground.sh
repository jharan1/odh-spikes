#!/usr/bin/env bash
# install-playground.sh — install the playground with the E2E embedding-model matrix
# via the gen-ai BFF install API (the code path PR #10314 changes).
#
# The install is TWO-PHASE because vector store validation requires the pgvector
# credentials Secret to already exist, but that Secret is only created by the
# pgvector auto-provisioning that runs during an install:
#
#   Phase 1: install with models only  -> auto-provisions pgvector + genai-pgvector-credentials
#   Phase 2: reconfigure-delete (preserve_vector_store=true) + install with models AND stores
#
# Usage:
#   NAMESPACE=embedding-e2e-100933 \
#   DASHBOARD_URL=https://rh-ai.apps.<cluster-domain> \
#   ./install-playground.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-embedding-e2e-100933}"
DASHBOARD_URL="${DASHBOARD_URL:?set DASHBOARD_URL, e.g. https://rh-ai.apps.example.com}"
TOKEN="${TOKEN:-$(oc whoami -t)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODELS='[
  {"model_name": "publishers/embedding-e2e-100933/models/gemini-proxy", "model_source_type": "maas"},
  {"model_name": "gemini-embedding-001", "model_source_type": "custom_endpoint", "model_type": "embedding", "embedding_dimension": 3072},
  {"model_name": "granite-embedding-keyless", "model_source_type": "custom_endpoint", "model_type": "embedding", "embedding_dimension": 768},
  {"model_name": "granite-embedding-r2", "model_source_type": "namespace", "model_type": "embedding", "embedding_dimension": 768},
  {"model_name": "RedHatAI/granite-embedding-english-r2", "model_source_type": "custom_endpoint", "model_type": "embedding", "embedding_dimension": 768}
]'
STORES='[
  {"vector_store_id": "vs-e2e-gemini-keyed"},
  {"vector_store_id": "vs-e2e-granite-keyless-ce"},
  {"vector_store_id": "vs-e2e-granite-isvc"},
  {"vector_store_id": "vs-e2e-granite-namespaced-ce"}
]'

echo ">>> Pre-flight: if a playground already exists, reconfigure-delete it first (keeps pgvector + data)"
if oc get ogxserver lsd-genai-playground -n "$NAMESPACE" >/dev/null 2>&1; then
  curl -s -f -X DELETE "$DASHBOARD_URL/gen-ai/api/v1/lsd/delete?namespace=$NAMESPACE" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"name": "lsd-genai-playground", "preserve_vector_store": true}' | jq .
  for i in $(seq 1 30); do
    oc get ogxserver lsd-genai-playground -n "$NAMESPACE" >/dev/null 2>&1 || break
    sleep 5
  done
fi

echo ">>> Phase 1: install (models only — provisions pgvector)"
curl -s -f -X POST "$DASHBOARD_URL/gen-ai/api/v1/lsd/install?namespace=$NAMESPACE" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"models\": $MODELS}" | jq .

echo ">>> Waiting for pgvector credentials secret (auto-provisioned)..."
for i in $(seq 1 30); do
  if oc get secret genai-pgvector-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "secret genai-pgvector-credentials present"
    break
  fi
  sleep 5
done
oc wait --for=condition=Available deployment/genai-pgvector -n "$NAMESPACE" --timeout=180s

echo ">>> Phase 2a: reconfigure-delete (keeps pgvector + data)"
curl -s -f -X DELETE "$DASHBOARD_URL/gen-ai/api/v1/lsd/delete?namespace=$NAMESPACE" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name": "lsd-genai-playground", "preserve_vector_store": true}' | jq .
# wait for the OGXServer to actually disappear
for i in $(seq 1 30); do
  oc get ogxserver lsd-genai-playground -n "$NAMESPACE" >/dev/null 2>&1 || break
  sleep 5
done

echo ">>> Phase 2b: install (models + vector stores)"
curl -s -f -X POST "$DASHBOARD_URL/gen-ai/api/v1/lsd/install?namespace=$NAMESPACE" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"models\": $MODELS, \"vector_stores\": $STORES}" | jq .

echo ">>> Waiting for playground rollout..."
oc wait --for=condition=Available deployment/lsd-genai-playground -n "$NAMESPACE" --timeout=300s
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True \
  ogxserver/lsd-genai-playground -n "$NAMESPACE" --timeout=300s 2>/dev/null || \
  echo "(ogxserver Ready condition not set yet — check: oc get ogxserver -n $NAMESPACE)"

echo
echo ">>> Verify the generated llama-stack-config shape (the fix under test):"
oc get cm llama-stack-config -n "$NAMESPACE" -o yaml | sed -n '/config.yaml/,/kind:/p' \
  | sed -n '/registered_resources/,$p'
echo
echo "Expected:"
echo "  - gemini-embedding-001                  under provider_id: genai-bff-proxy   (keyed, proxy-routed)"
echo "  - granite-embedding-keyless             under provider_id: genai-bff-proxy   (keyless, proxy-routed)"
echo "  - RedHatAI/granite-embedding-english-r2 under provider_id: genai-bff-proxy   (namespaced CE, proxy-routed — model_id preserved verbatim)"
echo "  - granite-embedding-r2                  under provider_id: vllm-inference-N  (namespace ISVC, unchanged; N = position in the install model list)"
echo "  - NO provider entry for gemini-embedding-provider / granite-embed-provider"
echo "  - vector store bindings:"
echo "      vs-e2e-gemini-keyed        -> genai-bff-proxy/gemini-embedding-001"
echo "      vs-e2e-granite-keyless-ce  -> genai-bff-proxy/granite-embedding-keyless"
echo "      vs-e2e-granite-isvc        -> vllm-inference-N/granite-embedding-r2"
echo "      vs-e2e-granite-namespaced-ce -> genai-bff-proxy/RedHatAI/granite-embedding-english-r2"
