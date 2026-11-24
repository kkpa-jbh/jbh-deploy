#!/usr/bin/env bash
# Portability check: fails if k8s/base/ holds a value that belongs to one target (laptop, VPS, AWS).
# The base must be the same everywhere; target values go in k8s/overlays/<target>/ (k8s/README.md, "Portability").
#
# Usage: scripts/check-k8s-base.sh   (from the jbh-deploy folder; CI runs it on every PR)
# It only renders YAML. It starts nothing and needs no cluster.
set -euo pipefail

base="${1:-k8s/base}"
rendered=$(kubectl kustomize --load-restrictor LoadRestrictionsNone "$base")

# Each pattern is a kind of target-only value. The message says where it belongs instead.
patterns=(
  'storageClassName:|a storage class (each target has its own storage)'
  'ingressClassName:|an Ingress controller name (Traefik on k3s, ALB on EKS)'
  '^ *- host:|^ *host:|a host name in an Ingress rule'
  '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+|an IP range'
  'localhost|a laptop address'
)

failed=0
for entry in "${patterns[@]}"; do
  regex="${entry%|*}"
  what="${entry##*|}"
  if grep -E -n "$regex" <<< "$rendered" >/dev/null; then
    echo "k8s/base holds ${what}. Move it to an overlay:" >&2
    grep -E -n "$regex" <<< "$rendered" | head -5 >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "k8s/base is target-neutral."
