#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# ActionLibrary: Terraform Control — release-asset acquisition
# ═══════════════════════════════════════════════════════════════════════════════
# Opt-in seam for artifact-based code deployment: instead of running Terraform
# against whatever the caller checked out, download the release's packaged asset,
# extract it, and run from the extracted content.
#
# Off by default. With RELEASE_TAG empty the script emits the caller's
# working-directory unchanged, so every existing call site is untouched.
#
# Boundary note: this covers ENROLLED-REPO CODE DEPLOYMENT only. Repo-config
# management (nexus_control / action-deploy_nexus-config) reads the live default
# branch by design — do not route that path through here.
#
# Inputs (environment):
#   RELEASE_TAG         release tag to deploy; empty = acquisition disabled
#   RELEASE_ASSET       asset filename; empty = <tag>.zip, else the sole .zip
#   RELEASE_REPOSITORY  owner/repo owning the release; empty = GH_REPOSITORY
#   RELEASE_PATH        sub-directory inside the asset to run from; empty = root
#   RELEASE_TOKEN       token with contents:read on RELEASE_REPOSITORY
#   WORKING_DIRECTORY   the action's working-directory input (fallback)
#
# Outputs ($GITHUB_OUTPUT): source_dir, release_asset, release_asset_size
#
# Line endings MUST stay LF. See .gitattributes.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# Failure capture: acquisition runs before anything that writes a summary, so a
# missing release, a 404 asset or a bad token used to end the action with an
# empty job summary. The cause is recorded here and rendered by the engine's
# "Engine failure summary" step.
# shellcheck source=scripts/nexus-summary.sh
. "$(dirname "$0")/nexus-summary.sh"
nexus_capture "Acquire deployment source"

release_tag="${RELEASE_TAG:-}"
working_directory="${WORKING_DIRECTORY:-.}"

emit() {
  printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"
}

fail() {
  echo "::error::terraform-control: $*" >&2
  nexus_note_cause "terraform-control: $*"
  exit 1
}

# ── Disabled path: behave exactly as before ───────────────────────────────────
if [ -z "$release_tag" ]; then
  emit source_dir "$working_directory"
  emit release_asset ""
  emit release_asset_size ""
  exit 0
fi

# ── Enabled path ──────────────────────────────────────────────────────────────
release_repository="${RELEASE_REPOSITORY:-}"
if [ -z "$release_repository" ]; then
  release_repository="${GH_REPOSITORY:-}"
fi
[ -n "$release_repository" ] || fail "release-repository could not be resolved."
[ -n "${RELEASE_TOKEN:-}" ] || fail "release-token is required when release-tag is set."

command -v curl >/dev/null 2>&1 || fail "curl is required to download release assets."
command -v jq   >/dev/null 2>&1 || fail "jq is required to resolve release assets."
command -v unzip >/dev/null 2>&1 || fail "unzip is required to extract release assets."

api_url="${GITHUB_API_URL:-https://api.github.com}"
work_root="${RUNNER_TEMP:-/tmp}/terraform-control-release"
rm -rf "$work_root"
mkdir -p "$work_root/download" "$work_root/src"

release_json="$work_root/release.json"
http_code="$(curl -sSL -o "$release_json" -w '%{http_code}' \
  -H "Authorization: Bearer ${RELEASE_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${api_url}/repos/${release_repository}/releases/tags/${release_tag}" || true)"

if [ "$http_code" != "200" ]; then
  fail "release '${release_tag}' not readable in ${release_repository} (HTTP ${http_code}). Check the tag exists and the token grants contents:read."
fi

asset_name="${RELEASE_ASSET:-}"
if [ -z "$asset_name" ]; then
  # Default naming is <release_version>.zip, which is <tag>.zip for root
  # releases. Folder releases carry a prefixed tag, so fall back to the release's
  # only zip asset and fail loudly when the choice is ambiguous.
  if jq -e --arg n "${release_tag}.zip" '.assets[] | select(.name == $n)' "$release_json" >/dev/null 2>&1; then
    asset_name="${release_tag}.zip"
  else
    zip_count="$(jq -r '[.assets[] | select(.name | endswith(".zip"))] | length' "$release_json")"
    if [ "$zip_count" = "1" ]; then
      asset_name="$(jq -r '[.assets[] | select(.name | endswith(".zip"))][0].name' "$release_json")"
    else
      fail "cannot pick a release asset for '${release_tag}': ${zip_count} .zip assets present [$(jq -r '[.assets[].name] | join(", ")' "$release_json")]. Set release-asset explicitly."
    fi
  fi
fi

asset_id="$(jq -r --arg n "$asset_name" 'first(.assets[] | select(.name == $n) | .id) // empty' "$release_json")"
[ -n "$asset_id" ] || fail "asset '${asset_name}' not found on release '${release_tag}' [$(jq -r '[.assets[].name] | join(", ")' "$release_json")]."

archive="$work_root/download/${asset_name}"
http_code="$(curl -sSL -o "$archive" -w '%{http_code}' \
  -H "Authorization: Bearer ${RELEASE_TOKEN}" \
  -H "Accept: application/octet-stream" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${api_url}/repos/${release_repository}/releases/assets/${asset_id}" || true)"
[ "$http_code" = "200" ] || fail "download of '${asset_name}' failed (HTTP ${http_code})."

# ── Sanity: present, non-empty, actually a zip ────────────────────────────────
[ -f "$archive" ] || fail "downloaded asset '${asset_name}' is missing."
asset_size="$(wc -c < "$archive" | tr -d '[:space:]')"
[ "$asset_size" -gt 0 ] || fail "downloaded asset '${asset_name}' is empty (0 bytes)."
if [ "$(head -c 2 "$archive")" != "PK" ]; then
  fail "asset '${asset_name}' is not a zip archive."
fi
unzip -tq "$archive" >/dev/null 2>&1 || fail "asset '${asset_name}' failed a zip integrity check."

unzip -q -o "$archive" -d "$work_root/src"

entry_count="$(find "$work_root/src" -mindepth 1 | wc -l | tr -d '[:space:]')"
[ "$entry_count" -gt 0 ] || fail "asset '${asset_name}' extracted to an empty tree."

source_dir="$work_root/src"
if [ -n "${RELEASE_PATH:-}" ]; then
  source_dir="$work_root/src/${RELEASE_PATH#/}"
fi
[ -d "$source_dir" ] || fail "release-path '${RELEASE_PATH:-}' does not exist inside '${asset_name}'."

# The extracted root must be a Terraform working directory — an asset that
# packaged the wrong root would otherwise plan an empty configuration and read
# as a clean 'no changes' run.
tf_count="$(find "$source_dir" -maxdepth 1 -name '*.tf' -type f | wc -l | tr -d '[:space:]')"
[ "$tf_count" -gt 0 ] || fail "no *.tf files at the root of '${asset_name}'${RELEASE_PATH:+ (release-path: ${RELEASE_PATH})} — not a Terraform working directory."

echo "Deployment source: ${release_repository}@${release_tag} asset ${asset_name} (${asset_size} bytes, ${entry_count} entries)"
echo "Running Terraform from: ${source_dir} (${tf_count} root .tf files)"

emit source_dir "$source_dir"
emit release_asset "$asset_name"
emit release_asset_size "$asset_size"
