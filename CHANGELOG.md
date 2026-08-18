# **ActionLibrary Terraform Control** | Changelog

| [Home](./README.md)
| **Changelog**
| [Contributing](./CONTRIBUTING.md)
| [Tech Doc](./techdoc.md)
| <!-- End Of Menu -->

---

## v1.1.0

**Release:** [v1.1.0](https://github.com/crosswave-technology/ActionLibrary-Terraform-Control/releases/tag/v1.1.0)  
**PR:** [Nexus: summary maximisation + Node24 modernisation (#14)](https://github.com/crosswave-technology/ActionLibrary-Terraform-Control/pull/14)  
**Labels:** Minor

# Terraform Control — summary box, failure capture and Node 24 pin sweep

## Summary

The engine already wrote a structured plan/apply box (rebuilt earlier in this
programme, nominal size 2,866 bytes). This change does not rebuild it. It fixes
the two defaults D2 identified, closes a byte-cap bypass on the apply path,
stops a renderer fault from discarding the whole report, and gives the steps
that run *outside* the plan/apply path — acquisition, install, init, fmt,
standalone validate, destroy — a way to report their failure instead of ending
the job with an empty summary.

**Diffstat:** `5 files changed, 550 insertions(+), 14 deletions(-)`

## Why

Sean's summary principles, applied to composite actions:

> "The Summary should be used at inform the user at a glance. If the user needs
> to go digging into the pipeline, we have not done enough to bubble these back
> up to the user. If a part fails, we should be cleanly passing this back to the
> summary without simply breaking. Also, some aspects should be isolated boxes,
> not bundled into a single output... if it is content bloated on the UI, it may
> be easier for users to look at the code than scroll the content."

That translates into four rules this pull request implements:

1. **At a glance.** One status line, then a table of the facts a reader
   actually needs. No prose to scroll past.
2. **Its own box.** Each action writes one ruled block, so a job that runs
   several actions reads as separate boxes rather than one wall of output.
3. **Failure reaches the summary first.** Critical steps are guarded; on any
   internal failure the cause is captured, written into the box, and only then
   is the non-zero exit propagated. Nothing is swallowed — the step still fails.
4. **Bounded.** Counts, tables, a first-error excerpt and links. Every cap says
   how much it left out and where the rest lives.


## Behavioural changes

Every change that alters what the action *does*, not just what it prints:

1. **`emit-raw-plan` default flipped `"true"` → `"false"`**  
   The raw `terraform show` dump is no longer appended unless asked for. **Consumer check: 24 of the 29 plan-path call sites in the estate pass `emit-raw-plan: "true"` explicitly** (20 workflow files across 19 repositories, 3 generator templates in `TerraformLibrary-Nexus-Repository`, and `ActionLibrary-Terraform-Deploy/action.yml`), so this flip changes nothing for them until those explicit values are removed. The one call site that stops passing it in this programme is Terraform-Deploy. Apply-path call sites never pass it and are unaffected either way.

   **Five plan-path call sites do rely on the default and will lose the raw dump once the engine is re-minted and re-pinned**: `ActionLibrary-Create-Log/.github/workflows/nexus_apply-repo-config.yml:232`, pinned `@v1.0.0` and therefore live at re-mint; and four in `GitHub-Nexus-Center` — `github-deploy_01-org-configuration.yml:71`, `github-deploy_02-github-teams.yml:78`, `pre-check_github-plan_01-org-configuration.yml:55` and `pre-check_github-plan_02-github-teams.yml:62`, all pinned `@v1.0.2` and therefore affected only when that pin moves. All five also leave `emit-summary` unset, whose default is `"true"`, so they do render a plan summary today and will keep rendering one — without the raw dump. This is the intended outcome, but it is a visible change for those five, not a no-op.

   `emit-full-plan: "true"` still forces the dump on.

2. **`summary-max-bytes` default lowered `900000` → `131072` (128 KiB)**  
   **No caller in the estate sets this input**, so this default is live the moment the action is re-minted. 900000 was a hair under GitHub's 1 MiB hard drop rather than a readable budget. Raise it per call where a genuinely large report is wanted.

3. **Apply path now honours the byte cap**  
   `scripts/terraform-summary.sh` appended the apply report to `$GITHUB_STEP_SUMMARY` without calling `truncate_summary_file`, so a large apply log could push the summary past GitHub's limit and lose the whole report — the exact failure the cap exists to prevent on the plan path. All three flush sites now go through one `flush_summary`.

4. **A renderer fault no longer discards the report**  
   The script accumulates the report in a temporary file and appends it at the end. Under `set -e`, any fault in between (a malformed plan, a failing helper) discarded everything and the job failed with an empty summary. An `ERR`/`EXIT` trap now writes what was built plus the cause, then re-raises the original exit code. The step still fails.

5. **New `Engine failure summary` step**  
   Renders one box **only when** acquisition, install, init, fmt, standalone validate or destroy recorded a failure. On a normal plan or apply it writes nothing, so the engine's plan/apply box remains the single box for that path. `destroy` previously produced no summary at all under any outcome.

6. **Each box is preceded by a horizontal rule**  
   Cosmetic, and the point of it: a job running several actions now reads as separate boxes rather than one continuous block.

## Node 24 pin sweep

Third-party actions re-pinned to the current latest stable release, SHA-pinned with the version in a trailing comment. SHAs are the dereferenced commit for each tag, resolved with `git ls-remote`.

| Action | Was | Now | Compatibility |
| --- | --- | --- | --- |
| `actions/github-script` | `v7.1.0` | `v9.0.0` | v8 moved to Node 24 (runner ≥ v2.327.1); v9 upgrades `@actions/github` to v9 and drops `require('@actions/github')` inside scripts. The PR-comment script here uses only `require("fs")`, `github.rest.*`, `github.paginate`, `context` and `core`, and never declares `getOctokit` — all compatible. |

All of these are JavaScript actions and all now run on **Node 24**, which requires an Actions runner of at least `v2.327.1`. GitHub-hosted runners are well past that; any self-hosted runner in the estate must be checked before the re-mint.

**Internal pins:** `crosswave-technology/ActionLibrary-Checkov-Control@v1.0.0` (×2) — internal pin, left as a tag by policy.

**Runtime:** this is a `composite` action, so it has no `runs.using: node16/node20` of its own. The Node runtime question applies only to the third-party JavaScript actions it calls, which the pin sweep above moves to Node 24.

### Shared mechanism — `scripts/nexus-summary.sh`

A single sourced library, identical in every ActionLibrary repository, provides:

| Function | Purpose |
| --- | --- |
| `nexus_capture "<step>" [meta]` | Installs `ERR`/`EXIT` traps. On a non-zero exit it records the step, exit code, source line, failing command and a redacted stderr tail, then re-raises the original code. `meta` mode records no output text at all — used by every step that touches a token. |
| `nexus_note_cause "<message>"` | Records the sentence the author wrote, so the box shows "Refusing to create an empty package…" rather than `exit 1`. |
| `nexus_box_begin/status/row/note/details/end` | Builds one ruled box. Sections are buffered and assembled in a fixed order, so the status line always leads regardless of the order the script fills the box in. |
| `nexus_redact` | Applied to every excerpt: credential URLs (`https://user:token@…`), `ghp_`/`gho_`/`ghs_`/`ghu_`/`ghr_` tokens, `github_pat_…`, `AKIA…`/`ASIA…` key IDs, private-key headers and `token=`/`secret=` style pairs become `***`. **Job summaries are not masked by the runner**, so this is the only thing standing between a `git` error message and a published credential. |

Caps: 25 table rows, 40 lines / 4,000 bytes per excerpt, 32 KiB per box, each
with a note naming what was dropped.


### Deliberately not changed

- The plan/apply box layout, status logic, PR-comment section machinery and
  resource-diff parser. This was a surgical pass.
- `emit-summary`, `summary-max-lines`, and every other input default.
- The gate semantics of `Fail if prechecks or plan failed`.

## Dormant until the re-mint

Every enrolled repository consumes this action at `@v1.0.0`, so **nothing in
this pull request changes any pipeline the moment it merges**. The new
behaviour appears only after the action is re-minted (a `v1.1.0` tag) and the
consuming repositories have their pins bumped to it. Both are later steps in
the promote chain and are deliberately out of scope here.

`VERSION` is untouched: the promote chain owns that file.


## Validation

See `VALIDATION.md` for the full evidence. In short: `action.yml` parses under both `yq` and PyYAML; `actionlint` is clean against a synthetic caller workflow that exercises every declared input and consumes every declared output; `shellcheck` is clean on every embedded `run:` block and every script, with no new findings against the pre-change baseline; and the summary scripts were executed against success, failure, oversized and missing-file fixtures.

<details>
<summary>Click to expand additional details:</summary>

---

#### PR Details
- Author: @SeanMcCann93
- Merged: 2026-08-18T19:42:13Z
- Merge commit: `31e51d9`
- Reviewers: (none)
- Files changed: 5 (+550 / -14)

</details>

## v1.0.0

**Release:** [v1.0.0](https://github.com/crosswave-technology/ActionLibrary-Terraform-Control/releases/tag/v1.0.0)  
**Labels:** Major

### Change Summary

Release baseline. Under the Nexus v2.1 clean re-baseline (ruling R3, plan step A6) this scope's release history and tags are wiped and re-minted at `v1.0.0` through the repaired pipeline. `Generate-Changelog` rebuilds `CHANGELOG.md` wholesale from `logs/*.md`, so this fragment is the whole of the recorded history from here on: it folds the pre-baseline narrative **and** the v2.1 wave changes into one entry.

The shared deployment engine under both template paths. This baseline is the release that carries the artifact-acquisition seam, and it is therefore the first release of the re-baseline sequence: every template and every strategy pin resolves to it. It also removes the reason the action could not be released at all — the inline summary block exceeded GitHub's 21,000-character template-string limit.

#### Baseline changes

- **E-8 / default #3 — the release gate.** The inline summary body evaluated to 27,477 characters against a 21,000 limit; any tag cut from that tree reproduced the v1.1.0 outage. The body is regenerated into `scripts/terraform-summary.sh` (LF, mojibake repaired) and referenced: the summary step's `run:` is now 55 characters with no expression, and the largest expression-bearing scalar in the file is 2,866 characters — 13.6 % of the limit.
- **A4 acquisition seam (new).** Five opt-in inputs — `release-tag`, `release-asset`, `release-repository`, `release-path`, `release-token` — a `scripts/acquire-release-asset.sh` step, and `source_dir` / `release_asset` / `release_asset_size` outputs. Every execution step resolves `working-directory` through `steps.acquire.outputs.source_dir || inputs.working-directory`. **Default off**: an empty `release-tag` leaves all 53 existing call sites byte-identical. The asset sanity check (missing, empty, or not a zip) lives here and nowhere else.
- **E-4a Checkov gate** — the fail step read `steps.checkov_gate`, a step id that does not exist (the id is `checkov`), so the gate branch was unreachable while the summary could print `blocked` on a passing run. Fixed, and `checkov-api-key` added on a second `if`-guarded step so no unexpected-input annotation reaches the 53 call sites.
- **E-14 summary correctness** — `has_errors` was tested against `terraform show` output, which structurally cannot contain plan errors, so a failed plan reported green. It now also tests the plan log and the error count the plan step already extracts.
- **Escaped-regex defects** — `destroy\\.` and `s/…/\\1/` made the plan-count fallback unmatchable and emitted the literal string `\1`; the awk stop-rule `/^No changes\\./` never matched. Both corrected.
- **New `plan-file` input** — relative paths resolve against the run directory, absolute paths are used as-is, parent directories are created, and `plan_text_file` follows. Default `""` reproduces today's `$(pwd)/terraform.plan` exactly.
- **E-18** — dead input `outputs-display` removed (declared, defaulted, referenced by no step, zero callers estate-wide).
- **E-12** — `action.yml` 56,017 B CRLF → 26,896 B LF; `.gitattributes` added so the CRLF regression that broke `terraform-summary.sh` at v1.1.4 cannot return.
- **C1 pin rewrite (W3)** — the Checkov-Control references move from the floating `@v1` to `@v1.0.0`, which is that repository's first Nexus-minted tag.

#### Consolidated history (pre-baseline)

3 superseded fragments are retained verbatim under `logs/archive/` — outside the `logs/*.md` glob this action rebuilds from, so they are preserved without reappearing as separate changelog entries. The recorded narrative is folded here:

| Version | Recorded change |
| --- | --- |
| `v1.1.5` | **action.yml** — Checkov step refactored: delegates to `ActionLibrary-Checkov-Control@v1` composite action.; **pre-check_overrides.yml** — AOS-005 Overrides Barrier CI gate added.; **.checkov.yaml** — Added config ski... |
| `v1.1.4` | scripts/terraform-summary.sh was committed with CRLF line endings. Bash treats pipefail<CR> as an invalid option name, causing set -euo pipefail on line 2 to fail with exit code 2 for all enrolled repos. |
| `v1.1.3` | The three env vars added in v1.1.2 (COMMENT_SECTION_ID, PLAN_ERROR_FILE, PLAN_ERROR_COUNT) had 10-space indentation instead of 8-space, causing a YAML parse error that failed the Set up job step in all enrolled repos. |
| `v1.1.2` | The extracted scripts/terraform-summary.sh in v1.1.1 contained three raw GitHub Actions expressions (inputs.comment-section-id, steps.plan.outputs.plan_error_file, steps.plan.outputs.plan_error_count) that were evalua... |
| `v1.1.1` | GitHub Actions enforces a 21,000 character limit on template string values. The Terraform summary step's inline un: script was 34,567 characters, causing all workflows using ActionLibrary-Terraform-Control@v1.1.0 to f... |
| `v1.1.0` | Upgrades the Terraform Control action to commercial-grade PR reporting with a consolidated comment architecture. All plan/pre-check output from a single workflow now lands in one PR comment using named section blocks,... |
| `v1.0.2` | Adds optional `git-modules-token` input to the Terraform Control action. When set, configures a git credential helper before `terraform init` so private TerraformLibrary modules can be cloned during init. |
| `v1.0.1` | Adds gitleaks secret scan workflow, .gitleaks.toml, .gitignore, and any missing standard repo files (CONTRIBUTING.md, techdoc.md, VERSION). |

---

<details>
<summary>Click to expand additional details:</summary>

#### Change Type(s)

- ✨ New Feature
- 🐛 Bug Fix
- 🔧 Tweak / 🛠️ Refactor
- 🔒 Security
- ⚙️ CI/CD

---

#### Baseline Details
- Author: @SeanMcCann93
- Baseline: `v1.0.0` (re-mint; wipes and replaces all prior releases and tags for this scope)
- Supersedes: `v1.1.5`, `v1.1.4`, `v1.1.3`, `v1.1.2`, `v1.1.1`, `v1.1.0`, `v1.0.2`, `v1.0.1`
- Archived fragments: 3 (`logs/archive/`: v1.0.1.md, v1.0.2.md, v1.1.0.md)
- Wave: Nexus v2.1 — W1/W2 source changes, W3 re-baseline (plan A6)

</details>
