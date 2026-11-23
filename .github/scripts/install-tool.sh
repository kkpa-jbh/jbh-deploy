#!/usr/bin/env bash
# Downloads one CLI tool from a GitHub release, checks its SHA-256, and puts it on the PATH of the job.
# Used by .github/workflows/ci.yml. A fixed version and checksum, so a changed release file fails the job
# instead of running unknown code (the same idea as pinning actions to a commit SHA).
#
# Usage: install-tool.sh <name> <url of a .tar.gz> <sha256 of that file>
#   <name> is the binary inside the archive (for example kubeconform).
set -euo pipefail

name="${1:?name}"
url="${2:?url}"
sha256="${3:?sha256}"

dir="${RUNNER_TEMP:-/tmp}/tools"
mkdir -p "$dir"
archive="$dir/${name}.tar.gz"

curl -fsSL "$url" -o "$archive"
echo "${sha256}  ${archive}" | sha256sum -c -
tar -xzf "$archive" -C "$dir" "$name"
chmod +x "$dir/$name"

# GITHUB_PATH: a file the runner reads after this step; folders in it are added to PATH for the next steps.
echo "$dir" >> "${GITHUB_PATH:?GITHUB_PATH is set only inside GitHub Actions}"
"$dir/$name" --version 2>/dev/null || "$dir/$name" version 2>/dev/null || true
