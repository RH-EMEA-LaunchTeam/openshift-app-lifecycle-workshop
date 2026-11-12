#!/usr/bin/env bash
# catch-up.sh
# Purpose: Recreate the end state of Session 1 in an empty namespace, so
#          Session 2 can start on a fresh cluster: both images built, notes-app
#          running with its ConfigMap, Secrets, PostgreSQL, probes and 3 replicas.
#          Needs only admin rights on the namespace (no cluster-admin).
#
# Usage:   ./20-session-prep/catch-up.sh <namespace> <context>
#          Run from the root of the repository. Takes about 3 minutes.
set -euo pipefail

NS="${1:?usage: $0 <namespace> <context>}"
CTX="${2:?usage: $0 <namespace> <context>}"
ocx() { oc --context "$CTX" -n "$NS" "$@"; }

[[ -d app && -d 15-stateless-and-scale ]] || { echo "Run from the repository root"; exit 1; }

echo "==> Building both images from app/ (legacy ~60s, hardened ~50s, in parallel)"
ocx apply -f 11-legacy-app/build.yaml -f 12-image-hygiene/build.yaml >/dev/null
ocx start-build notes-legacy --from-dir=app --wait >/dev/null &
legacy=$!
ocx start-build notes-app --from-dir=app --wait >/dev/null &
hardened=$!
wait "$legacy" || { echo "legacy build failed: oc logs bc/notes-legacy -n $NS --context $CTX"; exit 1; }
wait "$hardened" || { echo "hardened build failed: oc logs bc/notes-app -n $NS --context $CTX"; exit 1; }

echo "==> Creating Secrets (skipped if they already exist)"
ocx get secret notes-app-token >/dev/null 2>&1 || \
  ocx create secret generic notes-app-token \
    --from-literal=API_TOKEN="workshop-token-$(openssl rand -hex 4)" >/dev/null
ocx get secret notes-db >/dev/null 2>&1 || \
  ocx create secret generic notes-db \
    --from-literal=username=notes \
    --from-literal=password="$(openssl rand -hex 12)" >/dev/null

echo "==> Deploying PostgreSQL"
ocx apply -f 15-stateless-and-scale/postgresql.yaml >/dev/null
ocx rollout status deploy/notes-db --timeout=180s >/dev/null

echo "==> Deploying notes-app (Session 1, Step 5 state)"
ocx apply -f 12-image-hygiene/service.yaml -f 12-image-hygiene/route.yaml \
          -f 13-config-and-secrets/configmap.yaml \
          -f 15-stateless-and-scale/deployment.yaml -f 15-stateless-and-scale/pdb.yaml >/dev/null
ocx rollout status deploy/notes-app --timeout=180s >/dev/null

route=$(ocx get route notes-app -o jsonpath='{.spec.host}')
echo
echo "Session 1 state ready. Version currently running:"
curl -sk "https://$route/api/info"
echo
echo "Next: export ROUTE=$route"
