#!/usr/bin/env bash
bucket_json="$RUNNER_TEMP/github-backup-bucket.json"
gcloud storage buckets describe "gs://${GCS_BUCKET}" --format=json > "$bucket_json"
python - "$bucket_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    bucket = json.load(handle)

# gcloud omits requester_pays when it is disabled.
bucket.setdefault("requester_pays", False)

expected = {
    "location": "US-CENTRAL1",
    "default_storage_class": "STANDARD",
    "public_access_prevention": "enforced",
    "requester_pays": False,
    "uniform_bucket_level_access": True,
}
failures = [
    f"{key}={bucket.get(key)!r}, expected {value!r}"
    for key, value in expected.items()
    if bucket.get(key) != value
]
soft_delete = bucket.get("soft_delete_policy", {})
retention = soft_delete.get("retentionDurationSeconds")
if retention is None:
    duration = str(soft_delete.get("retentionDuration", ""))
    retention = duration.removesuffix("s") if duration else None
retention = str(retention)
if retention != "604800":
    failures.append(f"soft-delete retention={retention!r}, expected '604800'")
versioning_enabled = bucket.get("versioning_enabled")
if versioning_enabled is None:
    versioning_enabled = bucket.get("versioning", {}).get("enabled", False)
if versioning_enabled:
    failures.append("object versioning must be disabled")
if failures:
    raise SystemExit("Bucket policy drift: " + "; ".join(failures))
PY
