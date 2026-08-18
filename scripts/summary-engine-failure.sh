#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# ActionLibrary: Terraform Control — engine failure box
# ═══════════════════════════════════════════════════════════════════════════════
# The Terraform summary step covers plan and apply. Everything before it —
# release-asset acquisition, Terraform install, init, fmt, standalone validate —
# and everything outside it — destroy — used to end the action with a red step
# and an empty job summary, which is exactly the "go and dig in the pipeline"
# outcome the summary work exists to remove.
#
# This step renders one box, and only when one of those steps recorded a
# failure. On a normal plan or apply it writes nothing, so the engine's own
# plan/apply box stays the single box for that path.
#
# Environment: COMMAND, WORKING_DIRECTORY, SOURCE_DIR, RELEASE_TAG.
# Line endings MUST stay LF.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# shellcheck source=scripts/nexus-summary.sh
. "$(dirname "$0")/nexus-summary.sh"

if [ ! -s "$NEXUS_CAUSE_FILE" ]; then
  exit 0
fi

nexus_box_begin "Terraform Control — step failure" "engine-failure"
# shellcheck disable=SC2119  # default cause file is intended
nexus_box_failure || true
nexus_box_status fail "the run stopped before Terraform ${COMMAND:-plan} could report"
nexus_box_row "Command" "${COMMAND:-plan}"
nexus_box_row "Working directory" "${WORKING_DIRECTORY:-.}"
if [ -n "${SOURCE_DIR:-}" ] && [ "${SOURCE_DIR:-}" != "${WORKING_DIRECTORY:-.}" ]; then
  nexus_box_row "Ran from" "${SOURCE_DIR}"
fi
if [ -n "${RELEASE_TAG:-}" ]; then
  nexus_box_row "Release tag" "${RELEASE_TAG}"
fi
nexus_box_link "Run" "$(nexus_run_url)"

nexus_box_end
