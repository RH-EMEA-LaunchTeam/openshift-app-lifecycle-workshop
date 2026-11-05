#!/usr/bin/env bash
# audit-namespace.sh
# Purpose: Check every Deployment in a namespace against the automatable items
#          of the platform admission checklist (Step 6) and print PASS/WARN/FAIL.
#
# Usage:   ./16-admission-checklist/audit-namespace.sh <namespace> <context>
# Needs:   oc, jq
#
# Optional environment variable:
#   ALLOWED_REGISTRIES  space-separated registry prefixes that count as approved
#                       (default: Red Hat registries + the cluster internal registry)
set -euo pipefail

NS="${1:?usage: $0 <namespace> <context>}"
CTX="${2:?usage: $0 <namespace> <context>}"
ALLOWED_REGISTRIES="${ALLOWED_REGISTRIES:-registry.access.redhat.com/ registry.redhat.io/ image-registry.openshift-image-registry.svc:5000/}"
INTERNAL="image-registry.openshift-image-registry.svc:5000/"
SECRET_PATTERN='(TOKEN|PASSWORD|PASSWD|SECRET|API_KEY|PRIVATE_KEY)'

ocx() { oc --context "$CTX" -n "$NS" "$@"; }

result() { # deployment item check status detail
  local color="" reset=""
  if [[ -t 1 ]]; then
    reset=$'\033[0m'
    case "$4" in
      PASS) color=$'\033[32m' ;;
      WARN) color=$'\033[33m' ;;
      FAIL) color=$'\033[31m' ;;
    esac
  fi
  printf '%-14s %-4s %-30s %s%-4s%s %s\n' "$1" "$2" "$3" "$color" "$4" "$reset" "${5:-}"
}

deployments=$(ocx get deploy -o name)
if [[ -z "$deployments" ]]; then
  echo "No Deployments found in namespace $NS"
  exit 0
fi

printf '%-14s %-4s %-30s %-4s %s\n' "DEPLOYMENT" "#" "CHECK" "RES" "DETAIL"
printf '%s\n' "------------------------------------------------------------------------------------------"

for d in $deployments; do
  name="${d#*/}"
  dj=$(ocx get "$d" -o json)
  selector=$(echo "$dj" | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
  pj=$(ocx get pods -l "$selector" -o json)
  podcount=$(echo "$pj" | jq '.items | length')

  # Image as actually pulled (pod spec is resolved through ImageStream lookup)
  if [[ "$podcount" -gt 0 ]]; then
    image=$(echo "$pj" | jq -r '.items[0].spec.containers[0].image')
  else
    image=$(echo "$dj" | jq -r '.spec.template.spec.containers[0].image')
  fi

  # 1. Arbitrary non-root UID
  scc=$(echo "$pj" | jq -r '.items[0].metadata.annotations["openshift.io/scc"] // "unknown"')
  crashing=$(echo "$pj" | jq -r '[.items[].status.containerStatuses[]? | select(.ready == false and (.restartCount > 0 or .state.terminated != null or (.state.waiting.reason // "") == "CrashLoopBackOff"))] | length')
  runas=$(echo "$dj" | jq -r '[.spec.template.spec.securityContext.runAsUser, .spec.template.spec.containers[].securityContext.runAsUser] | map(select(. != null)) | first // "unset"')
  if [[ "$runas" == "0" || ( "$scc" != restricted* && "$scc" != "unknown" ) ]]; then
    result "$name" 1 "Non-root, arbitrary UID" FAIL "scc=$scc runAsUser=$runas"
  elif [[ "$crashing" -gt 0 ]]; then
    result "$name" 1 "Non-root, arbitrary UID" FAIL "pods crash under scc=$scc (check logs for permission errors)"
  else
    result "$name" 1 "Non-root, arbitrary UID" PASS "scc=$scc"
  fi

  # 2. Approved image source
  ok=FAIL
  for r in $ALLOWED_REGISTRIES; do [[ "$image" == "$r"* ]] && ok=PASS; done
  result "$name" 2 "Approved registry" "$ok" "${image%%@*}"

  # Base image provenance for images built in-cluster: read the FROM line of the
  # latest build of the BuildConfig with the same name as the ImageStream.
  if [[ "$image" == "$INTERNAL"* ]]; then
    path="${image#"$INTERNAL"}"; rest="${path#*/}"; isname="${rest%%[@:]*}"
    build=$(ocx get builds -l "openshift.io/build-config.name=$isname" -o json 2>/dev/null \
      | jq -r '.items | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty' || true)
    if [[ -n "$build" ]]; then
      base=$(ocx logs "build/$build" 2>/dev/null | grep -m1 -E 'STEP 1/[0-9]+: FROM' | sed -E 's/.*FROM +//; s/ .*//' || true)
      if [[ -n "$base" ]]; then
        ok=FAIL
        for r in $ALLOWED_REGISTRIES; do [[ "$base" == "$r"* ]] && ok=PASS; done
        result "$name" 2 "Approved base image" "$ok" "$base"
      fi
    fi
  fi

  # 3. Digest-pinned image
  if [[ "$(echo "$dj" | jq -r '.spec.template.spec.containers[0].image')" == *@sha256:* ]]; then
    result "$name" 3 "Image pinned by digest" PASS ""
  else
    result "$name" 3 "Image pinned by digest" WARN "template uses a tag: $(echo "$dj" | jq -r '.spec.template.spec.containers[0].image')"
  fi

  # 4a. No literal secrets in the manifest
  lit=$(echo "$dj" | jq -r --arg p "$SECRET_PATTERN" '[.spec.template.spec.containers[].env[]? | select(.value != null) | select(.name | test($p; "i")) | .name] | join(",")')
  if [[ -n "$lit" ]]; then
    result "$name" 4 "No secrets in manifest" FAIL "literal value for: $lit"
  else
    result "$name" 4 "No secrets in manifest" PASS ""
  fi

  # 4b. No secrets in the image metadata (internal images only)
  if [[ "$image" == "$INTERNAL"* && "$image" == *@sha256:* ]]; then
    path="${image#"$INTERNAL"}"; isns="${path%%/*}"; rest="${path#*/}"; isname="${rest%%@*}"; digest="${image##*@}"
    envs=$(oc --context "$CTX" -n "$isns" get isimage "$isname@$digest" -o json 2>/dev/null \
      | jq -r --arg p "$SECRET_PATTERN" '[.image.dockerImageMetadata.Config.Env[]? | split("=")[0] | select(test($p; "i"))] | join(",")' || true)
    if [[ -n "$envs" ]]; then
      result "$name" 4 "No secrets in image" FAIL "image ENV contains: $envs"
    else
      result "$name" 4 "No secrets in image" PASS ""
    fi
  else
    result "$name" 4 "No secrets in image" WARN "external image: inspect it with 'oc image info'"
  fi

  # 6. Probes
  probes=$(echo "$dj" | jq -r '.spec.template.spec.containers[0] | [ (if .readinessProbe then "readiness" else empty end), (if .livenessProbe then "liveness" else empty end) ] | join(",")')
  case "$probes" in
    "readiness,liveness") result "$name" 6 "Health probes" PASS "$probes" ;;
    "")                   result "$name" 6 "Health probes" FAIL "none" ;;
    *)                    result "$name" 6 "Health probes" WARN "only $probes" ;;
  esac

  # 7. Resources
  req=$(echo "$dj" | jq -r '.spec.template.spec.containers[0].resources.requests.memory // empty')
  lim=$(echo "$dj" | jq -r '.spec.template.spec.containers[0].resources.limits.memory // empty')
  if [[ -n "$req" && -n "$lim" ]]; then
    result "$name" 7 "Requests and memory limit" PASS "req=$req lim=$lim"
  else
    result "$name" 7 "Requests and memory limit" FAIL "not declared (LimitRange defaults apply)"
  fi

  # 8. State
  hostpath=$(echo "$dj" | jq -r '[.spec.template.spec.volumes[]? | select(.hostPath)] | length')
  pvcs=$(echo "$dj" | jq -r '[.spec.template.spec.volumes[]? | select(.persistentVolumeClaim)] | length')
  replicas=$(echo "$dj" | jq -r '.spec.replicas')
  if [[ "$hostpath" -gt 0 ]]; then
    result "$name" 8 "Stateless or explicit state" FAIL "uses hostPath"
  elif [[ "$pvcs" -gt 0 ]]; then
    result "$name" 8 "Stateless or explicit state" WARN "uses $pvcs PVC(s): needs a backup and restore plan"
  else
    result "$name" 8 "Stateless or explicit state" PASS "no volumes (verify the app does not write local state)"
  fi

  # 10. Ports, replicas, graceful shutdown
  lowport=$(echo "$dj" | jq -r '[.spec.template.spec.containers[].ports[]?.containerPort | select(. < 1024)] | join(",")')
  if [[ -n "$lowport" ]]; then
    result "$name" 10 "Unprivileged ports" FAIL "port(s) $lowport"
  else
    result "$name" 10 "Unprivileged ports" PASS ""
  fi
  if [[ "$replicas" -ge 2 ]]; then
    result "$name" 10 "Survives pod loss (replicas)" PASS "replicas=$replicas"
  else
    result "$name" 10 "Survives pod loss (replicas)" WARN "replicas=$replicas"
  fi
done

echo
echo "Items 5 (externalised configuration) and 9 (logs to stdout) need a manual review."
