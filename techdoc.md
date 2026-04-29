# **ActionLibrary-Terraform-Control** | Tech Doc

| [Home](./README.md)
| [Changelog](./CHANGELOG.md)
| [Contributing](./CONTRIBUTING.md)
| **Tech Doc**
| <!-- End Of Menu -->

---

## Purpose

Reusable GitHub Actions workflow for running Terraform plan and apply across multi-account deployment matrices. Handles OIDC credential acquisition, account matrix generation from `accounts/` group files, and the plan/apply promotion gate.

## Design Notes

- Credentials are acquired via GitHub OIDC — no static AWS keys are stored.
- The deployment matrix is built dynamically from `accounts/*.json` group files, merged with `vars.ACCOUNT_OVERRIDES` and `vars.ADDITIONAL_ACCOUNTS`.
- Plan always runs before apply; apply is gated on plan success and environment approval.
- State isolation is per-account: `<repo_account_id>/<group>/<target_account_id>/terraform.tfstate`.

## Required Repository Variables

| Variable | Description |
|---|---|
| `REPO_ACCOUNT_ID` | Account ID owning the state bucket |
| `STATE_BUCKET_NAME` | S3 bucket name for Terraform state |
| `ACCOUNT_OVERRIDES` | (optional) JSON to override account fields |
| `ADDITIONAL_ACCOUNTS` | (optional) JSON to append extra accounts |
