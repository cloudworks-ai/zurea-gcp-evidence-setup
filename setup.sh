#!/usr/bin/env bash
# Zurea – GCP Evidence Setup (WIF / AWS → GCP, config-only)
# - Creates Evidence SA in the target project
# - Grants least-privilege read-only roles (no object data)
# - Binds your AWS role (via Workload Identity Pool) to impersonate the SA
# - Optional: temporary local verify (adds/removes TokenCreator for current user)

set -euo pipefail

# Make gcloud fully non-interactive (auto-approve prompts)
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

# ========= YOU provide these (publish on your docs/website) =========
# Your GCP host project number (numeric), WIF pool id, and your AWS role details:
HOST_PROJECT_NUMBER="${HOST_PROJECT_NUMBER:-26979796123}"
WIF_POOL_ID="${WIF_POOL_ID:-zurea-aws-pool}"
WIF_PROVIDER_ID="${WIF_PROVIDER_ID:-aws-main}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-294393683475}"
AWS_ROLE_NAME="${AWS_ROLE_NAME:-ZureaGCPCollectorReadRole}"

# ========= Defaults (customer can override flags) =========
EVIDENCE_SA_NAME="${EVIDENCE_SA_NAME:-zurea-evidence}"
CUSTOM_ROLE_ID="${CUSTOM_ROLE_ID:-zureaBucketMetadataViewer}"
DO_VERIFY="${DO_VERIFY:-0}"                   # 1 => temp TokenCreator to current user to verify now

usage() {
  cat <<USG >&2
Usage: $0 --project <PROJECT_ID> [--sa-name NAME] [--verify] \\
          [--host-project-number N] [--pool-id ID] [--provider-id ID] \\
          [--aws-account-id ID] [--aws-role-name NAME]

Required:
  --project <PROJECT_ID>              Customer project ID to connect

Optional (usually prefilled by vendor docs; can be overridden):
  --sa-name <NAME>                    Evidence SA name (default: ${EVIDENCE_SA_NAME})
  --verify                            Temporarily allow current user to impersonate SA to verify, then remove
  --host-project-number <NUM>         (default: ${HOST_PROJECT_NUMBER})
  --pool-id <ID>                      WIF pool id (default: ${WIF_POOL_ID})
  --provider-id <ID>                  WIF provider id (default: ${WIF_PROVIDER_ID})
  --aws-account-id <ID>               Your AWS account id (default: ${AWS_ACCOUNT_ID})
  --aws-role-name <NAME>              Your AWS collector role name (default: ${AWS_ROLE_NAME})

Environment overrides:
  HOST_PROJECT_NUMBER, WIF_POOL_ID, WIF_PROVIDER_ID, AWS_ACCOUNT_ID, AWS_ROLE_NAME,
  EVIDENCE_SA_NAME, CUSTOM_ROLE_ID, DO_VERIFY
USG
  exit 1
}

# ========= Parse args =========
PROJECT_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2;;
    --sa-name) EVIDENCE_SA_NAME="$2"; shift 2;;
    --verify) DO_VERIFY=1; shift;;
    --host-project-number) HOST_PROJECT_NUMBER="$2"; shift 2;;
    --pool-id) WIF_POOL_ID="$2"; shift 2;;
    --provider-id) WIF_PROVIDER_ID="$2"; shift 2;;
    --aws-account-id) AWS_ACCOUNT_ID="$2"; shift 2;;
    --aws-role-name) AWS_ROLE_NAME="$2"; shift 2;;
    *) usage;;
  esac
done
[[ -z "${PROJECT_ID}" ]] && usage

# ========= Derived =========
EVIDENCE_SA_EMAIL="${EVIDENCE_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
WIF_PRINCIPAL="principalSet://iam.googleapis.com/projects/${HOST_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/attribute.aws_role/${AWS_ROLE_NAME}"

echo ">> Project: ${PROJECT_ID}"
echo ">> Evidence SA: ${EVIDENCE_SA_EMAIL}"
echo ">> WIF principal: ${WIF_PRINCIPAL}"

# ========= Prechecks =========
command -v gcloud >/dev/null || { echo "gcloud not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found (Cloud Shell includes jq)"; exit 1; }
ACTIVE="$(gcloud config get-value account 2>/dev/null || true)"
[[ -z "$ACTIVE" ]] && { echo "Not logged in. Run: gcloud auth login"; exit 1; }
gcloud config set project "${PROJECT_ID}" >/dev/null

echo ">> Enabling required APIs (idempotent)..."
# Minimal APIs that do not require billing (needed for IAM/WIF and verification)
gcloud services enable \
  cloudresourcemanager.googleapis.com iam.googleapis.com iamcredentials.googleapis.com serviceusage.googleapis.com \
  storage.googleapis.com cloudkms.googleapis.com logging.googleapis.com monitoring.googleapis.com \
  sts.googleapis.com >/dev/null

# Enable heavy APIs only if billing is enabled (compute/container/sql)
BILLING_ENABLED="$(gcloud beta billing projects describe "${PROJECT_ID}" --format='value(billingEnabled)' 2>/dev/null || true)"
if [[ "${BILLING_ENABLED}" == "True" ]]; then
  echo ">> Project has billing enabled; enabling compute/container/sqladmin APIs…"
  gcloud services enable \
    compute.googleapis.com container.googleapis.com sqladmin.googleapis.com >/dev/null
else
  echo ">> Billing not enabled; skipping compute/container/sqladmin API activation."
fi

# ========= Create Evidence SA (idempotent) =========
if gcloud iam service-accounts describe "${EVIDENCE_SA_EMAIL}" >/dev/null 2>&1; then
  echo ">> Evidence SA exists."
else
  echo ">> Creating Evidence SA..."
  gcloud iam service-accounts create "${EVIDENCE_SA_NAME}" \
    --display-name="Zurea Evidence (read-only)" \
    --description="Read-only evidence collection for compliance" >/dev/null
fi

# ========= Grant least-privilege roles (no data/object reads) =========
echo ">> Granting read-only roles…"
for ROLE in \
  roles/iam.securityReviewer \
  roles/serviceusage.serviceUsageViewer \
  roles/cloudkms.viewer \
  roles/compute.networkViewer \
  roles/compute.viewer \
  roles/monitoring.alertPolicyViewer \
  roles/monitoring.notificationChannelViewer \
  roles/container.viewer \
  roles/cloudsql.viewer
do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${EVIDENCE_SA_EMAIL}" --role="${ROLE}" >/dev/null || true
done

#!/usr/bin/env bash
# Storage: least-priv custom role for bucket metadata only
echo ">> Ensuring custom role '${CUSTOM_ROLE_ID}' (storage.buckets.list/get)…"
cat > /tmp/zurea_bucket_meta_viewer.yaml <<'YAML'
title: Zurea Bucket Metadata Viewer
stage: GA
description: List buckets and read bucket-level config only (no object access).
includedPermissions:
- storage.buckets.list
- storage.buckets.get
- storage.buckets.getIamPolicy
YAML
if ! gcloud iam roles describe "${CUSTOM_ROLE_ID}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam roles create "${CUSTOM_ROLE_ID}" \
    --project "${PROJECT_ID}" --file=/tmp/zurea_bucket_meta_viewer.yaml --quiet >/dev/null
else
  gcloud iam roles update "${CUSTOM_ROLE_ID}" \
    --project "${PROJECT_ID}" --file=/tmp/zurea_bucket_meta_viewer.yaml --quiet >/dev/null
fi
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${EVIDENCE_SA_EMAIL}" \
  --role="projects/${PROJECT_ID}/roles/${CUSTOM_ROLE_ID}" >/dev/null

# ========= Bind WIF principal to impersonate Evidence SA =========
echo ">> Granting roles/iam.workloadIdentityUser to your AWS role (via WIF) on the Evidence SA…"
gcloud iam service-accounts add-iam-policy-binding "${EVIDENCE_SA_EMAIL}" \
  --member="${WIF_PRINCIPAL}" \
  --role="roles/iam.workloadIdentityUser" >/dev/null

# ========= Optional: local verification (temp grant to current user) =========
if [[ "${DO_VERIFY}" -eq 1 ]]; then
  echo ">> [Verify] Temporarily allowing current user to impersonate Evidence SA…"
  gcloud iam service-accounts add-iam-policy-binding "${EVIDENCE_SA_EMAIL}" \
    --member="user:${ACTIVE}" --role="roles/iam.serviceAccountTokenCreator" >/dev/null

  echo ">> [Verify] Trying to get token and list buckets…"
  TOKEN="$(gcloud auth print-access-token --impersonate-service-account="${EVIDENCE_SA_EMAIL}")" || {
    echo "!! Could not impersonate for verification. Check org policies."
  }

  if [[ -n "${TOKEN:-}" ]]; then
    RESP="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
      "https://storage.googleapis.com/storage/v1/b?project=${PROJECT_ID}")"
    COUNT="$(echo "$RESP" | jq -r '.items | length // 0')"
    echo "Buckets visible: ${COUNT}"
  fi

  echo ">> [Verify] Removing temporary TokenCreator from current user…"
  gcloud iam service-accounts remove-iam-policy-binding "${EVIDENCE_SA_EMAIL}" \
    --member="user:${ACTIVE}" --role="roles/iam.serviceAccountTokenCreator" >/dev/null || true
fi

echo
echo "SUCCESS ✅"
echo "Project: ${PROJECT_ID}"
echo "Evidence SA: ${EVIDENCE_SA_EMAIL}"
echo "WIF principal bound: ${WIF_PRINCIPAL}"
echo "Note: Your AWS role can now impersonate this SA via Workload Identity Federation."