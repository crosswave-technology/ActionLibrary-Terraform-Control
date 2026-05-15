# **ActionLibrary Terraform Control** | Changelog

| [Home](./README.md)
| **Changelog**
| [Contributing](./CONTRIBUTING.md)
| [Tech Doc](./techdoc.md)
| <!-- End Of Menu -->

---


## v1.1.1

**Release:** [v1.1.1](https://github.com/crosswave-technology/ActionLibrary-Terraform-Control/releases/tag/v1.1.1)
**Labels:** Patch

## Problem

GitHub Actions enforces a 21,000 character limit on template string values. The Terraform summary step's inline un: script was 34,567 characters, causing all workflows using ActionLibrary-Terraform-Control@v1.1.0 to fail with:

`
The template is not valid. ... (Line: 442, Col: 12): Exceeded max expression length 21000
`

## Solution

Extracted the large inline shell script to scripts/terraform-summary.sh. The composite action step now calls it via un: bash "${{ github.action_path }}/scripts/terraform-summary.sh". No functional changes to the script logic.

## Changes

- ction.yml: Replaced 832-line inline un: block with un: bash "${{ github.action_path }}/scripts/terraform-summary.sh".
- scripts/terraform-summary.sh: New file — extracted summary generation script.
- VERSION: 1.1.0 → 1.1.1
- CHANGELOG.md: Added v1.1.1 entry.
## v1.1.0

Upgrades the Terraform Control action to commercial-grade PR reporting with a consolidated comment architecture. All plan/pre-check output from a single workflow now lands in one PR comment using named section blocks, eliminating per-action comment clutter.

## Changes

- **New input `comment-section-id`** — section ID for consolidated PR comment. Auto-derived from working-directory slug when empty.
- **New outputs `plan_error_count` / `plan_error_file`** — structured error extraction on plan exit code 1, replacing the TRACE re-run anti-pattern.
- **Commercial-grade plan summary** — emoji status line (🟢/🟡/🔴), resource counts table, collapsible error details block, Checkov findings section, full-plan diff expander.
- **Section-replacement comment manager** — upserts only the current section by ID inside the shared `<!-- crosswave-terraform-report -->` comment; size-guarded to 65 kB.
- **Removed TRACE re-run** — `TF_LOG=TRACE` re-execution on plan failure removed; errors extracted from existing plan log via awk.

## v1.0.2
﻿## Summary

Adds optional `git-modules-token` input to the Terraform Control action. When set, configures a git credential helper before `terraform init` so private TerraformLibrary modules can be cloned during init.

## Changes

- New input `git-modules-token` (optional, default empty)
- New step **Configure git for private modules** — runs only when token is non-empty, injects it as a git URL credential helper before Terraform Init

## Why

AL-009: `terraform init` fails with `Invalid username or token` when consumers reference private TerraformLibrary modules and no credential helper is configured. Callers can now pass the token directly via the action input.

## Usage

Pass the token in the `with:` block when calling the action directly. GitHub-Nexus-Repository already pre-configures git at the caller level and does not need this input.

## v1.0.1
Adds gitleaks secret scan workflow, .gitleaks.toml, .gitignore, and any missing standard repo files (CONTRIBUTING.md, techdoc.md, VERSION).
