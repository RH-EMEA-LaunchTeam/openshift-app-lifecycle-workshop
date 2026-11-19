#!/usr/bin/env bash
# catch-up.sh
# Purpose: Recreate the end state of an earlier session in an empty namespace,
#          so the next session can start on a fresh cluster.
#          Session 2 (default): the end state of Session 1 - both images built,
#          notes-app running with its ConfigMap, Secrets, PostgreSQL, probes and
#          3 replicas.
#          Session 3: the above, plus the end state of Session 2 - the pipeline-ws
#          claim, the promote-image and acs-image-scan Tasks and version 2 of the
#          notes-app-build Pipeline.
#          Needs only admin rights on the namespace (no cluster-admin).
#
# Usage:   ./20-session-prep/catch-up.sh <namespace> <context> [2|3]
#          The third argument is the session you are about to start (default 2).
#          Run from the root of the repository. Takes about 3 minutes.
set -euo pipefail

NS="${1:?usage: $0 <namespace> <context> [2|3]}"
CTX="${2:?usage: $0 <namespace> <context> [2|3]}"
SESSION="${3:-2}"
[[ "$SESSION" == 2 || "$SESSION" == 3 ]] || { echo "session must be 2 or 3"; exit 1; }
ocx() { oc --context "$CTX" -n "$NS" "$@"; }

[[ -d app && -d 15-stateless-and-scale ]] || { echo "Run from the repository root"; exit 1; }

ocx apply -f 11-legacy-app/build.yaml -f 12-image-hygiene/build.yaml >/dev/null
if ocx get istag notes-legacy:latest >/dev/null 2>&1; then
  echo "==> Legacy image already provided by the platform team, building notes-app only (~50s)"
  ocx start-build notes-app --from-dir=app --wait >/dev/null \
    || { echo "build failed: oc logs bc/notes-app -n $NS --context $CTX"; exit 1; }
else
  echo "==> Building both images from app/ (legacy ~60s, hardened ~50s, in parallel)"
  ocx start-build notes-legacy --from-dir=app --wait >/dev/null &
  legacy=$!
  ocx start-build notes-app --from-dir=app --wait >/dev/null &
  hardened=$!
  wait "$legacy" || { echo "legacy build failed: oc logs bc/notes-legacy -n $NS --context $CTX"; exit 1; }
  wait "$hardened" || { echo "hardened build failed: oc logs bc/notes-app -n $NS --context $CTX"; exit 1; }
fi

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

if [[ "$SESSION" == 3 ]]; then
  echo "==> Session 2 end state: workspace claim, Tasks and notes-app-build version 2"
  ocx apply -f 21-pipelines-basics/workspace-pvc.yaml \
            -f 22-source-pipeline/promote-task.yaml \
            -f 23-scan-gate/acs-scan-task.yaml -f 23-scan-gate/pipeline.yaml >/dev/null
fi

route=$(ocx get route notes-app -o jsonpath='{.spec.host}')
# A new route takes a few seconds before the router serves it
for _ in $(seq 1 30); do
  curl -sfk "https://$route/api/info" >/dev/null 2>&1 && break
  sleep 2
done
echo
echo "Session $((SESSION - 1)) state ready. Version currently running:"
curl -sk "https://$route/api/info"
echo
echo "Next: export ROUTE=$route"
