#!/usr/bin/env bash
# Run once per schedule. This script only creates a Resource Manager Apply job.
set -euo pipefail

: "${OCI_STACK_ID:?Set OCI_STACK_ID to the existing snt-sync-free-vm stack OCID}"
: "${OCI_STACK_CONFIG_SHA256:?Set the expected SHA-256 of main.tf inside the Terraform ZIP}"
: "${OCI_STACK_VARIABLES_SHA256:?Set the expected SHA-256 of the stack variables}"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-1344}"
if ! [[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "MAX_ATTEMPTS must be a positive integer" >&2
  exit 1
fi
if ! [[ "$OCI_STACK_CONFIG_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "OCI_STACK_CONFIG_SHA256 must be a SHA-256 hex digest" >&2
  exit 1
fi
if ! [[ "$OCI_STACK_VARIABLES_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "OCI_STACK_VARIABLES_SHA256 must be a SHA-256 hex digest" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

result() {
  local status="$1" message="$2"
  printf '%s\n' "$message"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'result=%s\n' "$status" >> "$GITHUB_OUTPUT"
  fi
}

# The generated stack was already checked to contain one A1 VM with 1 OCPU
# and 6 GB RAM. Never auto-approve edits to that reviewed configuration.
oci resource-manager stack get-stack-tf-config \
  --stack-id "$OCI_STACK_ID" --file "$tmp_dir/config.zip" >/dev/null
actual_hash="$(python3 - "$tmp_dir/config.zip" <<'PY'
import hashlib
from pathlib import Path
import sys
from zipfile import ZipFile

with ZipFile(Path(sys.argv[1])) as archive:
    if archive.namelist() != ['main.tf']:
        raise SystemExit('Unexpected Terraform files in stack; manual review required')
    print(hashlib.sha256(archive.read('main.tf')).hexdigest())
PY
)"
if [[ "${actual_hash,,}" != "${OCI_STACK_CONFIG_SHA256,,}" ]]; then
  result BLOCKED "Stack configuration changed. Automatic Apply is blocked."
  exit 0
fi

# OCI keeps stack variable values outside the downloaded configuration ZIP.
# Pin them too so a later edit cannot change the VM size or other parameters.
oci resource-manager stack get --stack-id "$OCI_STACK_ID" > "$tmp_dir/stack.json"
actual_variables_hash="$(jq -cS '.data.variables // {}' "$tmp_dir/stack.json" | sha256sum | cut -d' ' -f1)"
if [[ "${actual_variables_hash,,}" != "${OCI_STACK_VARIABLES_SHA256,,}" ]]; then
  result BLOCKED "Stack variables changed. Automatic Apply is blocked."
  exit 0
fi

oci resource-manager job list \
  --stack-id "$OCI_STACK_ID" --all > "$tmp_dir/jobs.json"

if jq -e 'any(.data[]?; .["lifecycle-state"] == "ACCEPTED" or
  .["lifecycle-state"] == "IN_PROGRESS" or .["lifecycle-state"] == "CANCELING")' \
  "$tmp_dir/jobs.json" >/dev/null; then
  result WAIT "A job is still active on this stack; no new job submitted."
  exit 0
fi

latest="$(jq -c '[.data[]?] | sort_by(.["time-created"]) | last // null' "$tmp_dir/jobs.json")"
if [[ "$latest" == "null" ]]; then
  result BLOCKED "No previous job found. Review the stack manually."
  exit 0
fi

latest_status="$(jq -r '.["lifecycle-state"]' <<< "$latest")"
latest_id="$(jq -r '.id' <<< "$latest")"
if [[ "$(jq -r '.operation' <<< "$latest")" != "APPLY" ]]; then
  result BLOCKED "The latest job is not Apply. Review the stack manually."
  exit 0
fi
case "$latest_status" in
  SUCCEEDED)
    # A stack with only the reviewed instance resource was pinned above.
    # An initially failed stack may have no downloadable Terraform state yet.
    result SUCCESS "Latest Apply succeeded. Stopping future retries; verify the VM in OCI."
    exit 0 ;;
  FAILED)
    oci resource-manager job get-job-logs-content \
      --job-id "$latest_id" > "$tmp_dir/last.log"
    if ! grep -qi 'Out of host capacity' "$tmp_dir/last.log"; then
      result BLOCKED "Last Apply failed for a reason other than host capacity; review logs."
      exit 0
    fi ;;
  *)
    result BLOCKED "Unexpected Apply status; review manually."
    exit 0 ;;
esac

attempts="$(jq '[.data[]? | select(.operation == "APPLY" and
  .["lifecycle-state"] == "FAILED")] | length' "$tmp_dir/jobs.json")"
if (( attempts >= MAX_ATTEMPTS )); then
  result BLOCKED "Attempt limit reached; review capacity and GitHub usage."
  exit 0
fi

# A single stack accepts one job at a time. An Apply failure due to a race is
# safe: no second VM was created by this command.
oci resource-manager job create-apply-job \
  --stack-id "$OCI_STACK_ID" \
  --execution-plan-strategy AUTO_APPROVED \
  --display-name "snt-capacity-retry-${GITHUB_RUN_ID:-manual}" \
  --query 'data.id' --raw-output > "$tmp_dir/new-job-id"
result QUEUED "Apply job submitted; its result will be checked on the next run."
