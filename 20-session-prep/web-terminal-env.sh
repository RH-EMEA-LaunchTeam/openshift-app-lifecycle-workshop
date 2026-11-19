# web-terminal-env.sh
# Purpose: Prepare an OpenShift Web Terminal session for the workshop, as an
#          alternative to myenv.sh on a workstation. Source it from the root of
#          the cloned repository:
#
#            source 20-session-prep/web-terminal-env.sh
#
#          It installs tkn from the cluster's own download (the Web Terminal
#          does not include it), adds an envsubst replacement if needed, names
#          the current context "lab", and exports NS, GIT_REPO_URL and ROUTE.
#          NS defaults to app-lifecycle-<your user>; export NS first to override.
#          The Web Terminal does not keep files when it restarts: if you reopen
#          it, clone the repository again and source this file again.

# tkn and the Pipelines as Code plugin, from the cluster's command-line downloads
if ! command -v tkn >/dev/null 2>&1; then
  mkdir -p "$HOME/bin"
  tkn_url=$(oc get consoleclidownload tkn -o jsonpath='{range .spec.links[*]}{.href}{"\n"}{end}' | grep -m1 'linux-amd64')
  curl -sk "$tkn_url" | tar -xz -C "$HOME/bin" ./tkn ./tkn-pac
fi
case ":$PATH:" in *":$HOME/bin:"*) ;; *) export PATH="$HOME/bin:$PATH" ;; esac

# The workshop manifests only use ${VAR} placeholders
if ! command -v envsubst >/dev/null 2>&1; then
  envsubst() { perl -pe 's/\$\{(\w+)\}/$ENV{$1}/g'; }
fi

# Every command in the workshop uses --context lab
current_ctx=$(oc config current-context)
[ "$current_ctx" = lab ] || oc config rename-context "$current_ctx" lab >/dev/null

export NS="${NS:-app-lifecycle-$(oc whoami)}"
export GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/RH-EMEA-LaunchTeam/openshift-app-lifecycle-workshop.git}"
ROUTE=$(oc get route notes-app -n "$NS" --context lab -o jsonpath='{.spec.host}' 2>/dev/null)
export ROUTE

echo "user:    $(oc whoami --context lab)"
echo "NS:      $NS"
echo "ROUTE:   ${ROUTE:-(not created yet - run the catch-up script)}"
echo "tkn:     $(tkn version --component client 2>/dev/null)"
