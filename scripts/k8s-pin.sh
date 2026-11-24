#!/usr/bin/env bash
# Pins each JBH image in a Kustomize overlay to the git SHA tag that "latest" points to now.
#
# Usage: scripts/k8s-pin.sh k8s/overlays/local/kustomization.yaml   (make k8s-pin does this)
#
# Why: the overlay's "images:" list is the one place that says which version of each service runs.
# A SHA tag is exact; "latest" moves. Changing a newTag and applying the overlay (make k8s-up) is what makes
# Kubernetes start a rollout: it replaces the pods one by one with the new image.
#
# How: GHCR lists each package's versions, newest first, with their tags. The version tagged "latest" also
# carries the 40-character git SHA tag (the image workflows push both tags on the same image).
# Needs: gh (logged in; the packages API needs a token even for public packages).
set -euo pipefail

file="${1:?usage: k8s-pin.sh <kustomization.yaml>}"
images=(jbh-iam jbh-personal-finance jbh-notification jbh-gateway jbh-web)

printf '%-22s %-42s %s\n' service old new
for name in "${images[@]}"; do
  # The SHA tag of the version that also has the tag "latest". Empty if none is found.
  sha=$(gh api "/orgs/kkpa-jbh/packages/container/${name}/versions?per_page=20" \
    --jq '[.[] | .metadata.container.tags | select(index("latest")) | .[] | select(test("^[0-9a-f]{40}$"))][0] // empty')
  if [ -z "$sha" ]; then
    echo "No SHA tag next to 'latest' for ${name}. Did its Image workflow run on main?" >&2
    exit 1
  fi
  # The newTag line right after "name: ghcr.io/kkpa-jbh/<name>" in the images list.
  old=$(awk -v img="ghcr.io/kkpa-jbh/${name}" '$0 ~ "name: "img"$" {getline; sub(/.*newTag: /, ""); print; exit}' "$file")
  awk -v img="ghcr.io/kkpa-jbh/${name}" -v tag="$sha" '
    { print }
    $0 ~ "name: "img"$" { getline; sub(/newTag: .*/, "newTag: " tag); print }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  printf '%-22s %-42s %s\n' "$name" "${old:-?}" "$sha"
done
echo "Now run: make k8s-up"
