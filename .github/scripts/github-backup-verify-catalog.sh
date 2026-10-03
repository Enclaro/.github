#!/usr/bin/env bash
set -euo pipefail

scratch="$RUNNER_TEMP/github-backup-catalog"
mkdir -p "$scratch"
remote="$scratch/remote.txt"
checksums="$scratch/checksums.txt"
manifest="$scratch/manifest.txt"

gcloud storage ls "gs://${GCS_BUCKET}/github/**/*.tar.gz" \
  | sed "s#^gs://${GCS_BUCKET}/github/##" \
  | sort -u > "$remote"
awk '{ path = $2; sub(/\r$/, "", path); sub(/^\.\//, "", path); print path }' backup/github/SHA256SUMS \
  | sort -u > "$checksums"
awk '
  /^archives:$/ { section=1; next }
  section && /^  - / { sub(/^  - /, ""); print; next }
  section { exit }
' backup/github/MANIFEST.txt | sort -u > "$manifest"

if ! diff -u "$remote" "$checksums"; then
  echo "::error::SHA256SUMS does not match the live archive set."
  exit 1
fi
if ! diff -u "$remote" "$manifest"; then
  echo "::error::MANIFEST.txt does not match the live archive set."
  exit 1
fi
