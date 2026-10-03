#!/usr/bin/env bash
set -euo pipefail

scratch="$RUNNER_TEMP/github-backup-retained"
mkdir -p "$scratch"
current_archives="$scratch/current-archives.txt"
remote_archives="$scratch/remote-archives.txt"
retained_archives="$scratch/retained-archives.txt"
previous_checksums="$scratch/previous-SHA256SUMS"
retained_checksums="$scratch/retained-SHA256SUMS"

find backup/github -type f -name '*.tar.gz' -printf '%P\n' \
  | sort -u > "$current_archives"

set +e
remote_output="$(gcloud storage ls "gs://${GCS_BUCKET}/github/**/*.tar.gz" 2>&1)"
remote_status=$?
set -e
if (( remote_status == 0 )); then
  printf '%s\n' "$remote_output" \
    | sed "s#^gs://${GCS_BUCKET}/github/##" \
    | sed '/^$/d' \
    | sort -u > "$remote_archives"
elif grep -q 'matched no objects' <<<"$remote_output"; then
  : > "$remote_archives"
else
  printf '%s\n' "$remote_output" >&2
  exit "$remote_status"
fi

comm -23 "$remote_archives" "$current_archives" > "$retained_archives"
: > "$retained_checksums"

if [[ -s "$retained_archives" ]]; then
  if ! gcloud storage cp \
    "gs://${GCS_BUCKET}/github/SHA256SUMS" "$previous_checksums" >/dev/null 2>&1; then
    echo "::error::Retained archives exist but the previous SHA256SUMS is unavailable."
    exit 1
  fi

  while IFS= read -r archive; do
    checksum_line="$(awk -v target="$archive" '
      {
        path = $2
        sub(/\r$/, "", path)
        sub(/^\.\//, "", path)
        if (path == target) { sub(/\r$/, ""); print; exit }
      }
    ' "$previous_checksums")"
    if [[ -z "$checksum_line" ]]; then
      echo "::error::Missing retained checksum for $archive."
      exit 1
    fi
    printf '%s\n' "$checksum_line" >> "$retained_checksums"
  done < "$retained_archives"
fi

cat "$retained_checksums" backup/github/SHA256SUMS \
  | sort -k2,2 > "$scratch/SHA256SUMS"
cp "$scratch/SHA256SUMS" backup/github/SHA256SUMS

repos="$scratch/repositories.txt"
awk '
  /^repositories:$/ { section=1; next }
  /^archives:$/ { section=0 }
  section && /^  - / { sub(/^  - /, ""); print }
' backup/github/MANIFEST.txt > "$repos"
sed -n 's/\.git\.tar\.gz$//p' "$retained_archives" >> "$repos"
sort -u -o "$repos" "$repos"

archives="$scratch/archives.txt"
cat "$current_archives" "$retained_archives" | sort -u > "$archives"
generated_at="$(sed -n 's/^generated_at=//p' backup/github/MANIFEST.txt | head -n 1)"

{
  printf 'generated_at=%s\n' "$generated_at"
  printf 'repository_count=%s\n' "$(wc -l < "$repos" | tr -d ' ')"
  printf 'archive_count=%s\n' "$(wc -l < "$archives" | tr -d ' ')"
  printf 'auth_mode=public-fallback\n'
  printf 'metadata_export_schema_current=3\n'
  printf 'metadata_export_schema_source=per-archive:EXPORT.json\n'
  if [[ -n "$FILTERED_REPOSITORY" ]]; then
    printf 'filtered_git=%s:paths-%s\n' "$FILTERED_REPOSITORY" "${FILTERED_PATHS// /,}"
  fi
  printf 'metadata_scope=live-archive-union\n'
  printf 'repositories:\n'
  sed 's/^/  - /' "$repos"
  printf 'archives:\n'
  sed 's/^/  - /' "$archives"
} > backup/github/MANIFEST.txt
