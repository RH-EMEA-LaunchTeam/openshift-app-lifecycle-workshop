#!/usr/bin/env bash
# platform-setup.sh
# Purpose: Instructor-only, run once per workshop cluster before Session 2
#          (cluster-admin). Installs OpenShift Pipelines, ACS and Web Terminal,
#          publishes the shared Tasks and Pipelines in platform-pipelines,
#          builds the legacy image once (one Docker Hub pull for everybody),
#          and prepares one namespace per participant: admin rights for the
#          user, the acs-api Secret, the legacy image and the Session 1
#          LimitRange and ResourceQuota guardrails.
#
# Usage:   ./20-session-prep/platform-setup.sh <context> <user> [<user>...]
#          Example: ./20-session-prep/platform-setup.sh lab user1 user2 user3
#          Each user gets the namespace ${NS_PREFIX}<user>, for example
#          app-lifecycle-user1. Run from the root of the repository.
#          Takes 15-20 minutes on a fresh cluster (mostly ACS). Safe to re-run.
# Needs:   oc, jq, curl, openssl, git
#
# Optional environment variables:
#   NS_PREFIX=app-lifecycle-   Prefix for participant namespaces
#   SKIP_ACS=1                 ACS is already installed; then ACS_PASSWORD must be set
#   ACS_PASSWORD               Central admin password (generated if not set)
set -euo pipefail

CTX="${1:?usage: $0 <context> <user> [<user>...]}"
shift
USERS=("$@")
[[ ${#USERS[@]} -gt 0 ]] || { echo "usage: $0 <context> <user> [<user>...]"; exit 1; }
[[ -d 20-session-prep ]] || { echo "Run from the repository root"; exit 1; }
NS_PREFIX="${NS_PREFIX:-app-lifecycle-}"
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

echo "==> 1/6 Operators (OpenShift Pipelines, ACS, Web Terminal)"
occ apply -f 20-session-prep/operators.yaml >/dev/null
wait_for "TektonConfig to be ready" 900 \
  occ wait tektonconfig/config --for=condition=Ready --timeout=5s
wait_for "pipelines-as-code route" 300 \
  occ get route pipelines-as-code-controller -n openshift-pipelines
# The operator ships the console plugin but does not always enable it; without
# it there is no Pipelines section (task graphs, logs) in the web console.
wait_for "pipelines console plugin" 300 occ get consoleplugin pipelines-console-plugin
if ! occ get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' | grep -q pipelines-console-plugin; then
  occ patch consoles.operator.openshift.io cluster --type=json \
    -p '[{"op":"add","path":"/spec/plugins/-","value":"pipelines-console-plugin"}]' >/dev/null
fi

if [[ "${SKIP_ACS:-0}" != 1 ]]; then
  echo "==> 2/6 ACS Central and SecuredCluster"
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
  echo "==> 2/6 ACS already installed (SKIP_ACS=1)"
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

echo "    registry integration: lets ACS pull from the internal registry to scan"
# A read-only identity that can pull every image in the internal registry. Images
# built by pipelines are scanned before any Deployment uses them, so ACS cannot
# rely on the pull secrets it discovers from running workloads.
occ get sa acs-registry-reader -n stackrox >/dev/null 2>&1 || occ create sa acs-registry-reader -n stackrox >/dev/null
occ adm policy add-cluster-role-to-user registry-viewer -z acs-registry-reader -n stackrox >/dev/null
if ! curl -sfk -u "admin:$ACS_PASSWORD" "https://$CENTRAL/v1/imageintegrations" \
     | jq -e '.integrations[] | select(.name=="openshift-internal-registry")' >/dev/null; then
  REG_TOKEN=$(occ create token acs-registry-reader -n stackrox --duration=720h)
  jq -n --arg t "$REG_TOKEN" '{name:"openshift-internal-registry", type:"docker", categories:["REGISTRY"],
      docker:{endpoint:"image-registry.openshift-image-registry.svc:5000", username:"acs-registry-reader",
              password:$t, insecure:true}}' \
    | curl -sfk -u "admin:$ACS_PASSWORD" -X POST "https://$CENTRAL/v1/imageintegrations" -d @- >/dev/null
fi

echo "==> 3/6 ACS API token for pipelines (Continuous Integration role)"
ROX_API_TOKEN=$(curl -sfk -u "admin:$ACS_PASSWORD" -X POST "https://$CENTRAL/v1/apitokens/generate" \
  -d "{\"name\":\"workshop-pipelines-$(date +%s)\",\"roles\":[\"Continuous Integration\"]}" | jq -r .token)
[[ -n "$ROX_API_TOKEN" && "$ROX_API_TOKEN" != null ]] || { echo "could not create ACS API token"; exit 1; }

# Scanner V4 loads its vulnerability database once after installation (can take
# 20-40 minutes). Scans fail until then, so wait until a real scan succeeds.
scan_ubi() {
  curl -sfk -u "admin:$ACS_PASSWORD" -X POST "https://$CENTRAL/v1/images/scan" \
    -d '{"imageName":"registry.access.redhat.com/ubi9/ubi-minimal:latest","force":true}' \
    | jq -e '.scan.components | length > 0'
}
wait_for "Scanner V4 vulnerability database (first install: 20-40 min)" 3600 scan_ubi

echo "==> 4/6 Shared pipelines in platform-pipelines"
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

echo "==> 5/6 Legacy image, built once in workshop-images"
occ get namespace workshop-images >/dev/null 2>&1 || occ create namespace workshop-images >/dev/null
occ apply -n workshop-images -f 11-legacy-app/build.yaml >/dev/null
if ! occ get istag notes-legacy:latest -n workshop-images >/dev/null 2>&1; then
  # Build from the committed app/ directory, not from local uncommitted changes
  archive=$(mktemp -t notes-legacy-XXXX).tar
  git archive --format=tar -o "$archive" HEAD:app
  occ start-build notes-legacy -n workshop-images --from-archive="$archive" --wait >/dev/null
  rm -f "$archive"
fi
# Participant namespaces and their pods may pull images from workshop-images
occ policy add-role-to-group system:image-puller system:authenticated system:serviceaccounts \
  -n workshop-images >/dev/null

echo "==> 6/6 Participant namespaces"
for user in "${USERS[@]}"; do
  ns="${NS_PREFIX}${user}"
  occ get namespace "$ns" >/dev/null 2>&1 || occ create namespace "$ns" >/dev/null
  occ adm policy add-role-to-user admin "$user" -n "$ns" >/dev/null
  occ create secret generic acs-api -n "$ns" \
    --from-literal=ROX_ENDPOINT=central.stackrox.svc:443 \
    --from-literal=ROX_API_TOKEN="$ROX_API_TOKEN" \
    --dry-run=client -o yaml | occ apply -f - >/dev/null
  occ apply -n "$ns" -f 14-health-and-resources/limitrange.yaml \
                     -f 14-health-and-resources/resourcequota.yaml >/dev/null
  # The "vendor" image: same ImageStream as Session 1, pre-filled from workshop-images
  occ apply -n "$ns" -f 11-legacy-app/build.yaml >/dev/null
  occ tag workshop-images/notes-legacy:latest "$ns/notes-legacy:latest" \
    --reference-policy=local >/dev/null
  echo "    $user -> $ns ready"
done

PAC_URL=$(occ get route pipelines-as-code-controller -n openshift-pipelines -o jsonpath='{.spec.host}')
cat <<EOF

Platform ready. Hand these to the participants:
  NS=${NS_PREFIX}<user>
  PAC_WEBHOOK_URL=https://$PAC_URL

Instructor only (keep private):
  ACS console:  https://$CENTRAL   (admin / $ACS_PASSWORD)
EOF
