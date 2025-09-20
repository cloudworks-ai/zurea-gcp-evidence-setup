# `README.md`
```markdown
# Zurea – GCP Evidence Setup (GCS bucket metadata)

This script creates a read-only service account in your project with just enough access to:
- list GCS buckets
- read each bucket’s encryption metadata (CMEK vs Google-managed)
It then grants Zurea’s collector permission to impersonate that account (no keys).

## One-click (Open in Cloud Shell)

[Open in Cloud Shell](https://console.cloud.google.com/cloudshell/open?git_repo=https://github.com/YOUR_ORG/zurea-gcp-evidence-setup&cloudshell_workspace=.&cloudshell_tutorial=docs/tutorial.md)

Or run directly:
```bash
curl -sSL https://raw.githubusercontent.com/YOUR_ORG/zurea-gcp-evidence-setup/main/setup.sh -o setup.sh
bash setup.sh --project YOUR_PROJECT_ID