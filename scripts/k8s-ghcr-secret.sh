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
# GHCR_TOKEN is required. The script never falls back to your gh CLI token: that token has more rights
# (repo, workflow), and anyone who can read Secrets in the cluster could take it.
# Never put the token in .env.k8s: that file becomes "jbh-secrets", and every service reads it as env vars.
#
# The token never goes into a command line (ps would show it) or into the output: it goes through a pipe.
set -euo pipefail

namespace="${1:-jbh}"
name="jbh-ghcr-pull"

if [ -z "${GHCR_TOKEN:-}" ]; then
  echo "GHCR_TOKEN is not set. Create a classic token with only read:packages, then run:" >&2
  echo "  export GHCR_TOKEN=<token>   (LOCAL-K8S.md, \"Before you start\")" >&2
  exit 1
fi
token="$GHCR_TOKEN"
user="${GHCR_USER:-$(gh api user --jq .login)}"

# A docker-registry Secret holds one JSON file (.dockerconfigjson) with "user:token" in Base64.
auth="$(printf '%s:%s' "$user" "$token" | base64 | tr -d '\n')"
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$auth" |
  kubectl create secret generic "$name" -n "$namespace" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=/dev/stdin \
    --dry-run=client -o yaml |
  kubectl apply -f - >/dev/null
echo "Secret $name is ready in namespace $namespace (GHCR user: $user)."
