#!/usr/bin/env bash
# platform-setup.sh
# Purpose: Instructor-only, run once per workshop cluster before Session 2
#          (cluster-admin). Installs OpenShift Pipelines and ACS, publishes the
#          shared Tasks and Pipelines in the platform-pipelines namespace, and
#          prepares every participant namespace: the acs-api Secret plus the
#          Session 1 LimitRange and ResourceQuota guardrails.
#
# Usage:   ./20-session-prep/platform-setup.sh <context> <namespace> [<namespace>...]
#          Run from the root of the repository. Takes 15-20 minutes on a fresh
#          cluster (mostly waiting for ACS Central). Safe to re-run.
# Needs:   oc, jq, curl, openssl
#
# Optional environment variables:
#   SKIP_ACS=1        ACS is already installed; then ACS_PASSWORD must be set
#   ACS_PASSWORD      Central admin password (generated if not set)
set -euo pipefail

CTX="${1:?usage: $0 <context> <namespace> [<namespace>...]}"
shift
NAMESPACES=("$@")
[[ ${#NAMESPACES[@]} -gt 0 ]] || { echo "usage: $0 <context> <namespace> [<namespace>...]"; exit 1; }
[[ -d 20-session-prep ]] || { echo "Run from the repository root"; exit 1; }
occ() { oc --context "$CTX" "$@"; }

wait_for() { # description, timeout-seconds, command...
  local what="$1" timeout="$2"; shift 2
  printf '    waiting for %s ' "$what"
  for _ in $(seq 1 $((timeout / 10))); do
    if "$@" >/dev/null 2>&1; then echo "ok"; return 0; fi
    printf '.'; sleep 10
  done
  echo " TIMEOUT"; return 1
}

echo "==> 1/5 Operators (OpenShift Pipelines, ACS)"
occ apply -f 20-session-prep/operators.yaml >/dev/null
wait_for "TektonConfig to be ready" 900 \
  occ wait tektonconfig/config --for=condition=Ready --timeout=5s
wait_for "pipelines-as-code route" 300 \
  occ get route pipelines-as-code-controller -n openshift-pipelines

if [[ "${SKIP_ACS:-0}" != 1 ]]; then
  echo "==> 2/5 ACS Central and SecuredCluster"
  wait_for "ACS CRDs" 600 occ get crd centrals.platform.stackrox.io securedclusters.platform.stackrox.io
  occ get namespace stackrox >/dev/null 2>&1 || occ create namespace stackrox >/dev/null
  if ! occ get secret central-admin-pass -n stackrox >/dev/null 2>&1; then
    ACS_PASSWORD="${ACS_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=')}"
    occ create secret generic central-admin-pass -n stackrox --from-literal=password="$ACS_PASSWORD" >/dev/null
  fi
  ACS_PASSWORD=$(occ get secret central-admin-pass -n stackrox -o jsonpath='{.data.password}' | base64 -d)
  occ apply -f 20-session-prep/acs-central.yaml >/dev/null
  wait_for "Central deployment" 900 occ rollout status deploy/central -n stackrox --timeout=5s
else
  echo "==> 2/5 ACS already installed (SKIP_ACS=1)"
  : "${ACS_PASSWORD:?set ACS_PASSWORD when SKIP_ACS=1}"
fi

CENTRAL=$(occ get route central -n stackrox -o jsonpath='{.spec.host}')
wait_for "Central API" 300 curl -sfk -u "admin:$ACS_PASSWORD" "https://$CENTRAL/v1/ping"

if [[ "${SKIP_ACS:-0}" != 1 ]] && ! occ get secret sensor-tls -n stackrox >/dev/null 2>&1; then
  echo "    generating init bundle"
  curl -sfk -u "admin:$ACS_PASSWORD" -X POST "https://$CENTRAL/v1/cluster-init/init-bundles" \
    -d "{\"name\":\"lab-$(date +%s)\"}" | jq -r .kubectlBundle | base64 -d \
    | occ apply -n stackrox -f - >/dev/null
fi
if [[ "${SKIP_ACS:-0}" != 1 ]]; then
  occ apply -f 20-session-prep/acs-secured-cluster.yaml >/dev/null
  wait_for "Sensor" 600 occ rollout status deploy/sensor -n stackrox --timeout=5s
fi

echo "==> 3/5 ACS API token for pipelines (Continuous Integration role)"
ROX_API_TOKEN=$(curl -sfk -u "admin:$ACS_PASSWORD" -X POST "https://$CENTRAL/v1/apitokens/generate" \
  -d "{\"name\":\"workshop-pipelines-$(date +%s)\",\"roles\":[\"Continuous Integration\"]}" | jq -r .token)
[[ -n "$ROX_API_TOKEN" && "$ROX_API_TOKEN" != null ]] || { echo "could not create ACS API token"; exit 1; }

echo "==> 4/5 Shared pipelines in platform-pipelines"
occ get namespace platform-pipelines >/dev/null 2>&1 || occ create namespace platform-pipelines >/dev/null
occ apply -n platform-pipelines \
  -f 22-source-pipeline/promote-task.yaml \
  -f 23-scan-gate/acs-scan-task.yaml \
  -f 25-vendor-image-intake/inspect-task.yaml \
  -f 25-vendor-image-intake/uid-test-task.yaml \
  -f 25-vendor-image-intake/gate-task.yaml \
  -f 26-pipeline-service/source-build-pipeline.yaml \
  -f 26-pipeline-service/vendor-intake-pipeline.yaml >/dev/null
# Every authenticated user may browse the catalogue (read-only)
occ adm policy add-role-to-group view system:authenticated -n platform-pipelines >/dev/null

echo "==> 5/5 Participant namespaces"
for ns in "${NAMESPACES[@]}"; do
  occ get namespace "$ns" >/dev/null 2>&1 || occ create namespace "$ns" >/dev/null
  occ create secret generic acs-api -n "$ns" \
    --from-literal=ROX_ENDPOINT=central.stackrox.svc:443 \
    --from-literal=ROX_API_TOKEN="$ROX_API_TOKEN" \
    --dry-run=client -o yaml | occ apply -f - >/dev/null
  occ apply -n "$ns" -f 14-health-and-resources/limitrange.yaml \
                     -f 14-health-and-resources/resourcequota.yaml >/dev/null
  echo "    $ns ready"
done

PAC_URL=$(occ get route pipelines-as-code-controller -n openshift-pipelines -o jsonpath='{.spec.host}')
cat <<EOF

Platform ready. Hand these to the participants:
  PAC_WEBHOOK_URL=https://$PAC_URL

Instructor only (keep private):
  ACS console:  https://$CENTRAL   (admin / $ACS_PASSWORD)
EOF
