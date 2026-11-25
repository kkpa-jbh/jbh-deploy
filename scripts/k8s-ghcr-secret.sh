#!/usr/bin/env bash
# Creates or updates the Secret "jbh-ghcr-pull" in the local cluster (current kubectl context).
# The GHCR images are private. Each Deployment names this Secret in "imagePullSecrets"
# (k8s/overlays/local/patches/image-pull-secret.yaml), so the node can pull them.
#
# Usage: scripts/k8s-ghcr-secret.sh [namespace]   (make k8s-ghcr-secret; make k8s-up runs it too)
#
# The token needs only "read:packages". Best: a classic personal access token with only that scope
# (GHCR does not accept fine-grained tokens):
#   export GHCR_TOKEN=<token>          # optional: GHCR_USER=<github user>, default: the gh login
# Without GHCR_TOKEN the script uses your gh CLI token. It works, but it has more rights (repo, workflow).
# Never put the token in .env.k8s: that file becomes "jbh-secrets", and every service reads it as env vars.
#
# The token never goes into a command line (ps would show it) or into the output: it goes through a pipe.
set -euo pipefail

namespace="${1:-jbh}"
name="jbh-ghcr-pull"

user="${GHCR_USER:-$(gh api user --jq .login)}"
if [ -n "${GHCR_TOKEN:-}" ]; then
  token="$GHCR_TOKEN"
else
  echo "GHCR_TOKEN is not set: using your gh token. For least rights, use a token with only read:packages." >&2
  token="$(gh auth token)"
fi

# A docker-registry Secret holds one JSON file (.dockerconfigjson) with "user:token" in Base64.
auth="$(printf '%s:%s' "$user" "$token" | base64 | tr -d '\n')"
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$auth" |
  kubectl create secret generic "$name" -n "$namespace" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=/dev/stdin \
    --dry-run=client -o yaml |
  kubectl apply -f - >/dev/null
echo "Secret $name is ready in namespace $namespace (GHCR user: $user)."
