#!/usr/bin/env bash
# deploy-agents.sh — create AgentProfiles and deploy agent sandboxes for the
# RHOAIENG-101172 sandbox embedding verification (static registration approach).
#
# Creates one agent per vector store in the E2E matrix, each with the MaaS
# Gemini 2.5 Flash-Lite chat LLM, then deploys it via POST /agent-deployments
# (the code path under test: BuildSandboxLlamaStackConfig + the embedding key
# Secret flow in CreateAgentDeploymentHandler).
#
# Usage:
#   NAMESPACE=embedding-e2e-100933 \
#   DASHBOARD_URL=https://rh-ai.apps.<cluster-domain> \
#   ./deploy-agents.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-embedding-e2e-100933}"
DASHBOARD_URL="${DASHBOARD_URL:?set DASHBOARD_URL, e.g. https://rh-ai.apps.example.com}"
TOKEN="${TOKEN:-$(oc whoami -t)}"
MAAS_MODEL="${MAAS_MODEL:-publishers/${NAMESPACE}/models/gemini-proxy}"
# The MaaS gateway host follows the cluster's app domain: https://maas.<domain>/
# (the catalog model URL — NOT the /maas-api control path, which is only for
# token issuance via the wrapper's MAAS_GATEWAY_URL).
CLUSTER_DOMAIN="${DASHBOARD_URL#*//}"   # strip scheme: rh-ai.apps.<domain>
CLUSTER_DOMAIN="${CLUSTER_DOMAIN#*.}"   # drop the first label:      apps.<domain>
CLUSTER_DOMAIN="${CLUSTER_DOMAIN%/}"    # strip any trailing slash
MAAS_URI="${MAAS_URI:-https://maas.${CLUSTER_DOMAIN}/}"
SUBSCRIPTION="${SUBSCRIPTION:-gemini-subscription}"

store_for() { # $1 = agent name -> vector store id
  case "$1" in
    agent-keyed-vs)       echo vs-e2e-gemini-keyed ;;
    agent-keyless-vs)     echo vs-e2e-granite-keyless-ce ;;
    agent-isvc-vs)        echo vs-e2e-granite-isvc ;;
    agent-namespaced-vs)  echo vs-e2e-granite-namespaced-ce ;;
    *) return 1 ;;
  esac
}

for AGENT in agent-keyed-vs agent-keyless-vs agent-isvc-vs agent-namespaced-vs; do
  STORE="$(store_for "$AGENT")"

  echo ">>> Creating AgentProfile for $AGENT (store: $STORE)"
  PROFILEResp=$(curl -s -X POST "$DASHBOARD_URL/gen-ai/api/v1/agent-profiles?namespace=$NAMESPACE" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg store "$STORE" --arg model "$MAAS_MODEL" --arg uri "$MAAS_URI" --arg sub "$SUBSCRIPTION" --arg name "$AGENT" '{
      spec: {
        displayName: $name,
        description: ("sandbox embedding e2e agent for " + $store),
        model: {id: $model, uri: $uri, sourceType: "maas", authorization: {maasSubscription: $sub}},
        vectorStores: {stores: [{id: $store}]}
      }
    }')")
  PROFILE_ID=$(echo "$PROFILEResp" | jq -r '.data.profileId // .profileId // empty')
  if [ -z "$PROFILE_ID" ] || [ "$PROFILE_ID" = "null" ]; then
    echo "FAILED to create profile: $PROFILEResp" | head -5
    exit 1
  fi
  echo "    profile: $PROFILE_ID"

  echo ">>> Deploying agent $AGENT"
  DEPLOYResp=$(curl -s -X POST "$DASHBOARD_URL/gen-ai/api/v1/agent-deployments?namespace=$NAMESPACE" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg name "$AGENT" --arg pid "$PROFILE_ID" '{
      name: $name,
      description: "sandbox embedding e2e",
      agentProfileId: $pid
    }')")
  ROUTE=$(echo "$DEPLOYResp" | jq -r '.routeUrl // .data.routeUrl // empty')
  if [ -z "$ROUTE" ]; then
    echo "FAILED to deploy: $DEPLOYResp" | head -8
    exit 1
  fi
  echo "    route: $ROUTE"
done

echo
echo ">>> Waiting for agent sandboxes to become ready..."
for i in $(seq 1 40); do
  READY=$(oc get sandboxes -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '[.items[] | .status.conditions[]? | select(.type=="Ready" and .status=="True")] | length')
  TOTAL=$(oc get sandboxes -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "    sandboxes ready: $READY/$TOTAL"
  [ "$TOTAL" -ge 4 ] && [ "$READY" = "$TOTAL" ] && break
  sleep 15
done

oc get sandboxes -n "$NAMESPACE"
