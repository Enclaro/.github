#!/usr/bin/env bash
set -euo pipefail

sum_bucket_bytes() {
  local soft_deleted="${1:-false}"
  local args=(--exhaustive)
  local output status
  if [[ "$soft_deleted" == "true" ]]; then
    args+=(--soft-deleted)
  fi

  set +e
  output="$(gcloud storage ls -l "gs://${GCS_BUCKET}/github/**" "${args[@]}" 2>&1)"
  status=$?
  set -e

  if (( status != 0 )); then
    if grep -q 'matched no objects' <<<"$output"; then
      echo 0
      return 0
    fi
    printf '%s\n' "$output" >&2
    return "$status"
  fi

  awk '$1 ~ /^[0-9]+$/ { total += $1 } END { printf "%.0f\n", total + 0 }' <<<"$output"
}

new_bytes="$(du -sb backup/github | cut -f1)"
live_bytes="$(sum_bucket_bytes false)"
soft_deleted_bytes="$(sum_bucket_bytes true)"
projected_bytes=$((new_bytes + live_bytes + soft_deleted_bytes))

echo "Live bytes: $live_bytes"
echo "Soft-deleted bytes: $soft_deleted_bytes"
echo "New backup bytes: $new_bytes"
echo "Worst-case projected billable bytes: $projected_bytes"

if (( projected_bytes > MAX_BILLABLE_BYTES )); then
  echo "::error::Projected billable storage exceeds the 4 GiB safety cap."
  exit 1
fi
