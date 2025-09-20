#!/usr/bin/env bash
# Zurea – GCP Evidence Setup (GCS bucket metadata, cross-project)
# Creates a read-only Evidence SA in the target project, grants least-priv perms,
# and lets your Collector SA impersonate it. Verifies by listing buckets + encryption.
set -euo pipefail

# ====== YOU set this once (your collector SA) ======
COLLECTOR_SA_EMAIL="${COLLECTOR_SA_EMAIL:-zurea-collector@cloudworks-gcp.iam.gserviceaccount.com}"

# Defaults (customers can override via flags)
EVIDENCE_SA_NAME="${EVIDENCE_SA_NAME:-zurea-evidence}"
CUSTOM_ROLE_ID="${CUSTOM_ROLE_ID:-zureaBucketMetadataViewer}"
USE_BASIC_VIEWER="${USE_BASIC_VIEWER:-0}"   # set --use-basic-viewer to grant roles/viewer instead of custom role

usage() {
  cat <<USG >&2
Usage: $0 --project <PROJECT_ID> [--sa-name <NAME>] [--use-basic-viewer]

Creates service account and grants read-only access to list buckets and read encryption metadata.
Then grants your collector SA impersonation and verifies access.

Required:
  --project <PROJECT_ID>        Customer project to scan

Optional:
  --sa-name <NAME>              Evidence SA name (default: ${EVIDENCE_SA_NAME})
  --use-basic-viewer            Use roles/viewer instead of the least-priv custom role

Environment overrides (advanced):
  COLLECTOR_SA_EMAIL=<your-collector@HOST.iam.gserviceaccount.com>
  EVIDENCE_SA_NAME=<name>  CUSTOM_ROLE_ID=<id>  USE_BASIC_VIEWER=0|1
USG
  exit 1
}

# ====== Parse flags ======
PROJECT_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2;;
    --sa-name) EVIDENCE_SA_NAME="$2"; shift 2;;
    --use-basic-viewer) USE_BASIC_VIEWER=1; shift;;
    *) usage;;
  esac
done
[[ -z "${PROJECT_ID}" ]] && usage

EVIDENCE_SA_EMAIL="${EVIDENCE_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# ====== Prechecks ======
command -v gcloud >/dev/null || { echo "gcloud not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found (Cloud Shell includes jq)"; exit 1; }

ACTIVE="$(gcloud config get-value account 2>/dev/null || true)"
[[ -z "$ACTIVE" ]] && { echo "Not logged in. Run: gcloud auth login"; exit 1; }

echo ">> Project: ${PROJECT_ID}"
echo ">> Running as: ${ACTIVE}"
echo ">> Collector SA: ${COLLECTOR_SA_EMAIL}"
gcloud config set project "${PROJECT_ID}" >/dev/null

echo ">> Enabling required APIs (idempotent)..."
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com storage.googleapis.com >/dev/null

# ====== Create Evidence SA (idempotent) ======
if gcloud iam service-accounts describe "${EVIDENCE_SA_EMAIL}" >/dev/null 2>&1; then
  echo ">> Evidence SA exists: ${EVIDENCE_SA_EMAIL}"
else
  echo ">> Creating Evidence SA: ${EVIDENCE_SA_EMAIL}"
  gcloud iam service-accounts create "${EVIDENCE_SA_NAME}" \
    --display-name="Zurea Evidence (read-only)" \
    --description="Read-only evidence collection for compliance" >/dev/null
fi

# ====== Grant minimal permissions to Evidence SA ======
if [[ "${USE_BASIC_VIEWER}" -eq 0 ]]; then
  # Least-priv custom role: list buckets + read metadata
  echo ">> Ensuring custom role '${CUSTOM_ROLE_ID}' with bucket metadata permissions..."
  if ! gcloud iam roles describe "${CUSTOM_ROLE_ID}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud iam roles create "${CUSTOM_ROLE_ID}" \
      --project "${PROJECT_ID}" \
      --title="Zurea Bucket Metadata Viewer" \
      --permissions="storage.buckets.list,storage.buckets.get" \
      --stage="GA" >/dev/null
  fi
  echo ">> Granting custom role to Evidence SA..."
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${EVIDENCE_SA_EMAIL}" \
    --role="projects/${PROJECT_ID}/roles/${CUSTOM_ROLE_ID}" >/dev/null
else
  # Broader read: project Viewer (includes bucket list/get)
  echo ">> Granting roles/viewer to Evidence SA (broader read)..."
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${EVIDENCE_SA_EMAIL}" \
    --role="roles/viewer" >/dev/null
fi

# ====== Allow your collector to impersonate Evidence SA ======
echo ">> Granting roles/iam.serviceAccountTokenCreator to your collector on the Evidence SA..."
gcloud iam service-accounts add-iam-policy-binding "${EVIDENCE_SA_EMAIL}" \
  --member="serviceAccount:${COLLECTOR_SA_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator" >/dev/null

# Also allow the currently authenticated user to impersonate the Evidence SA
# so that the verification step below can run from Cloud Shell.
echo ">> Granting roles/iam.serviceAccountTokenCreator to the current user for verification..."
gcloud iam service-accounts add-iam-policy-binding "${EVIDENCE_SA_EMAIL}" \
  --member="user:${ACTIVE}" \
  --role="roles/iam.serviceAccountTokenCreator" >/dev/null || true

# ====== Verify: impersonation + bucket list + encryption ======
echo ">> Verifying impersonation and bucket visibility..."

# IAM policy updates can take a short time to propagate. Retry impersonation.
ACCESS_TOKEN=""
for attempt in {1..12}; do
  if ACCESS_TOKEN="$(gcloud auth print-access-token --impersonate-service-account="${EVIDENCE_SA_EMAIL}" 2>/dev/null)"; then
    break
  fi
  echo ".. waiting for IAM propagation (attempt ${attempt}/12)"
  sleep 5
done

if [[ -z "${ACCESS_TOKEN}" ]]; then
  echo "WARN: Could not impersonate ${EVIDENCE_SA_EMAIL} from user ${ACTIVE} after retries."
  echo "      This may be due to org policy restrictions on user-to-service-account impersonation."
  echo "      The collector service account (${COLLECTOR_SA_EMAIL}) DOES have TokenCreator on the Evidence SA."
  echo "      If this is expected, you can skip in-shell verification."
  exit 0
fi

BUCKETS_JSON="$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://storage.googleapis.com/storage/v1/b?project=${PROJECT_ID}")"

echo "Bucket,Encryption"
if [[ "$(echo "${BUCKETS_JSON}" | jq -r '.items | length // 0')" -eq 0 ]]; then
  echo "(no buckets found)"
else
  for b in $(echo "${BUCKETS_JSON}" | jq -r '.items[].name'); do
    ENC_JSON="$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "https://storage.googleapis.com/storage/v1/b/${b}?fields=encryption")"
    if echo "${ENC_JSON}" | jq -e '.encryption.defaultKmsKeyName' >/dev/null; then
      echo "${b},CMEK"
    else
      echo "${b},Google-managed"
    fi
  done
fi

echo
echo "SUCCESS ✅"
echo "Evidence SA: ${EVIDENCE_SA_EMAIL}"
echo "Impersonation granted to collector: ${COLLECTOR_SA_EMAIL}"
echo "Project scanned: ${PROJECT_ID}"