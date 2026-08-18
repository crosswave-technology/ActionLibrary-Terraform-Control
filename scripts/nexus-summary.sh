#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# ActionLibrary: shared job-summary box renderer and failure capture
# ═══════════════════════════════════════════════════════════════════════════════
# Sourced (never executed) by the composite steps of this action.
#
# Why it exists
#   Every action must tell the reader what happened at a glance, in its own
#   ruled box, without making anyone open the raw log. When an internal step
#   fails, the cause has to reach that box *before* the failure propagates -
#   a red X with no reason is the thing this file removes.
#
# Two halves
#   1. Failure capture - nexus_capture installs ERR/EXIT traps in a step. On a
#      non-zero exit it appends the step name, exit code, source line, failing
#      command and a redacted stderr tail to a cause file, then re-raises the
#      original exit code. Nothing is swallowed.
#   2. Box rendering   - nexus_box_* build one bounded markdown block and flush
#      it to $GITHUB_STEP_SUMMARY once, under a byte budget.
#
# Bounded by construction
#   Counts and tables, never dumps. Rows cap at NEXUS_ROWS_MAX, excerpts at
#   NEXUS_EXCERPT_MAX_LINES / NEXUS_EXCERPT_MAX_BYTES, the whole box at
#   NEXUS_BOX_MAX_BYTES. Every cut says so and points at the run log.
#
# Redaction
#   Excerpts pass through nexus_redact before they reach the summary: credential
#   URLs, GitHub tokens, AWS key IDs, private-key headers and key=value secrets
#   are replaced with ***. Job summaries are not masked by the runner, so this
#   is the only thing standing between a git error and a published token.
#
# Line endings MUST stay LF - a CR turns `set -euo pipefail` into a syntax
# error on the runner. See .gitattributes.
# ═══════════════════════════════════════════════════════════════════════════════

# Idempotent: sourcing twice in one shell is a no-op.
# shellcheck disable=SC2317  # reached only when the library is sourced twice
if [ -n "${NEXUS_SUMMARY_LIB:-}" ]; then
  return 0 2>/dev/null || true
fi
NEXUS_SUMMARY_LIB="1"

NEXUS_TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
# Whole-box budget. GitHub drops a step summary over 1 MiB; long before that a
# box stops being "at a glance", so the default is deliberately small.
NEXUS_BOX_MAX_BYTES="${NEXUS_BOX_MAX_BYTES:-32768}"
NEXUS_EXCERPT_MAX_LINES="${NEXUS_EXCERPT_MAX_LINES:-40}"
NEXUS_EXCERPT_MAX_BYTES="${NEXUS_EXCERPT_MAX_BYTES:-4000}"
NEXUS_ROWS_MAX="${NEXUS_ROWS_MAX:-25}"
NEXUS_CAUSE_FILE="${NEXUS_CAUSE_FILE:-${NEXUS_TMP}/nexus-failure.txt}"

# ── Redaction ────────────────────────────────────────────────────────────────
# stdin -> stdout. Applied to every excerpt that reaches a summary.
nexus_redact() {
  sed -E \
    -e 's/\x1B\[[0-9;]*[A-Za-z]//g' \
    -e 's#(https?://)[^/@[:space:]]+@#\1***@#g' \
    -e 's/gh[pousr]_[A-Za-z0-9]{16,}/***/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/***/g' \
    -e 's/(AKIA|ASIA)[0-9A-Z]{16}/***/g' \
    -e 's/-----BEGIN[A-Z ]*PRIVATE KEY-----/***REDACTED PRIVATE KEY***/g' \
    -e 's/(token|secret|password|api[_-]?key|private[_-]?key)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\2***/Ig'
}

# ── Failure capture ──────────────────────────────────────────────────────────
NEXUS_CLEANUP=""

# nexus_cleanup_add '<command>' - run at step exit, before the failure record is
# written. Single-quote the argument: it is evaluated at exit time. Use this
# instead of `trap ... EXIT`, which would replace the capture handler.
nexus_cleanup_add() {
  NEXUS_CLEANUP="${NEXUS_CLEANUP}${1}
"
}

# nexus_capture "<step name>" [meta]
#   Installs the traps. Pass "meta" as the second argument to record only the
#   step name / exit code / failing command and never the stderr text - used by
#   steps that handle token material.
nexus_capture() {
  NEXUS_STEP="${1:-step}"
  NEXUS_CAPTURE_MODE="${2:-stderr}"
  NEXUS_ERR_LINE=""
  NEXUS_ERR_CMD=""
  NEXUS_STDERR_LOG="${NEXUS_TMP}/nexus-stderr-$$.log"
  : > "$NEXUS_STDERR_LOG"
  set -E
  # shellcheck disable=SC2064  # LINENO/BASH_COMMAND must expand when the trap fires
  trap 'NEXUS_ERR_LINE="$LINENO"; NEXUS_ERR_CMD="$BASH_COMMAND"' ERR
  trap 'nexus__on_exit "$?"' EXIT
  if [ "$NEXUS_CAPTURE_MODE" != "meta" ]; then
    # stdout is untouched: workflow commands (::add-mask::, ::error::) and
    # $GITHUB_OUTPUT writes must keep their exact ordering.
    exec 2> >(tee -a "$NEXUS_STDERR_LOG" >&2)
  fi
}

nexus__on_exit() {
  nexus__rc="${1:-0}"
  trap - EXIT ERR
  nexus__run_cleanup
  if [ "$nexus__rc" -ne 0 ]; then
    nexus__write_cause "$nexus__rc"
  fi
  exit "$nexus__rc"
}

nexus__run_cleanup() {
  if [ -n "$NEXUS_CLEANUP" ]; then
    eval "$NEXUS_CLEANUP" || true
    NEXUS_CLEANUP=""
  fi
}

# nexus_note_cause "<message>" - record a human-written reason for the failure
# the step is about to raise. Call it immediately before `exit 1` (typically
# from an existing fail() helper) so the box shows the sentence the author
# wrote rather than whichever shell command happened to be running.
nexus_note_cause() {
  printf 'message=%s\n' "${1:-}" | nexus_redact >> "$NEXUS_CAUSE_FILE" 2>/dev/null || true
}

nexus__write_cause() {
  nexus__code="$1"
  # The failing command is redacted too: `git clone https://x-access-token:<pat>@...`
  # is a perfectly ordinary $BASH_COMMAND and job summaries are not masked.
  {
    echo "step=${NEXUS_STEP:-step}"
    echo "exit_code=${nexus__code}"
    echo "line=${NEXUS_ERR_LINE:-}"
    printf 'command=%s\n' "${NEXUS_ERR_CMD:-}" | nexus_redact
  } >> "$NEXUS_CAUSE_FILE" 2>/dev/null || true

  if [ "${NEXUS_CAPTURE_MODE:-meta}" != "meta" ] && [ -n "${NEXUS_STDERR_LOG:-}" ]; then
    # Restoring fd 2 closes the pipe to tee, which then flushes and exits.
    exec 2>&1
    sleep 0.2
    if [ -s "$NEXUS_STDERR_LOG" ]; then
      {
        echo "stderr<<NEXUS_EOF"
        tail -n "$NEXUS_EXCERPT_MAX_LINES" "$NEXUS_STDERR_LOG" \
          | head -c "$NEXUS_EXCERPT_MAX_BYTES" \
          | nexus_redact
        echo "NEXUS_EOF"
      } >> "$NEXUS_CAUSE_FILE" 2>/dev/null || true
    fi
  fi
  echo "---" >> "$NEXUS_CAUSE_FILE" 2>/dev/null || true
}

# ── Box rendering ────────────────────────────────────────────────────────────
# Sections are buffered separately and assembled in a fixed order by
# nexus_box_end: rule, heading, status, table, notes, details. Callers may add
# them in whatever order the script's control flow makes natural - the status
# line still lands first, where a reader looks.
NEXUS_BOX_FILE=""
NEXUS_BOX_ROWS=0
NEXUS_BOX_ROWS_DROPPED=0
NEXUS_BOX_FLUSHED="0"

nexus__escape_cell() {
  printf '%s' "$1" | tr '\n\r' '  ' | sed -e 's/|/\\|/g'
}

# nexus_box_begin "<Title>" [box-id]
nexus_box_begin() {
  NEXUS_BOX_TITLE="${1:-Summary}"
  nexus__box_id="${2:-box}"
  NEXUS_BOX_FILE="${NEXUS_TMP}/nexus-${nexus__box_id}.md"
  NEXUS_BOX_STATUS_FILE="${NEXUS_BOX_FILE}.status"
  NEXUS_BOX_ROWS_FILE="${NEXUS_BOX_FILE}.rows"
  NEXUS_BOX_NOTES_FILE="${NEXUS_BOX_FILE}.notes"
  NEXUS_BOX_DETAILS_FILE="${NEXUS_BOX_FILE}.details"
  : > "$NEXUS_BOX_STATUS_FILE"
  : > "$NEXUS_BOX_ROWS_FILE"
  : > "$NEXUS_BOX_NOTES_FILE"
  : > "$NEXUS_BOX_DETAILS_FILE"
  NEXUS_BOX_ROWS=0
  NEXUS_BOX_ROWS_DROPPED=0
  NEXUS_BOX_FLUSHED="0"
}

# nexus_box_status <ok|warn|fail|skip> "<detail>" - last call wins.
nexus_box_status() {
  nexus__state="${1:-ok}"
  nexus__detail="${2:-}"
  case "$nexus__state" in
    ok)   nexus__icon=":heavy_check_mark:" ;;
    warn) nexus__icon=":warning:" ;;
    fail) nexus__icon=":x:" ;;
    skip) nexus__icon=":fast_forward:" ;;
    *)    nexus__icon=":grey_question:" ;;
  esac
  printf '%s %s - %s\n\n' "$nexus__icon" "$NEXUS_BOX_TITLE" "$nexus__detail" > "$NEXUS_BOX_STATUS_FILE"
}

# nexus_box_row "<Field>" "<Value>" - capped at NEXUS_ROWS_MAX rows.
nexus_box_row() {
  if [ "$NEXUS_BOX_ROWS" -ge "$NEXUS_ROWS_MAX" ]; then
    NEXUS_BOX_ROWS_DROPPED=$(( NEXUS_BOX_ROWS_DROPPED + 1 ))
    return 0
  fi
  printf '| %s | %s |\n' "$(nexus__escape_cell "${1:-}")" "$(nexus__escape_cell "${2:-}")" >> "$NEXUS_BOX_ROWS_FILE"
  NEXUS_BOX_ROWS=$(( NEXUS_BOX_ROWS + 1 ))
}

# nexus_box_note "<markdown line>" - free text below the table.
nexus_box_note() {
  {
    echo "${1:-}"
    echo ""
  } >> "$NEXUS_BOX_NOTES_FILE"
}

# nexus_box_table_file "<file>" - append a pre-built markdown table (rows and
# header included) to the notes area. The file is trusted to be bounded by its
# producer; the whole-box cap still applies.
nexus_box_table_file() {
  nexus__tbl="${1:-}"
  [ -n "$nexus__tbl" ] && [ -s "$nexus__tbl" ] || return 0
  {
    cat "$nexus__tbl"
    echo ""
  } >> "$NEXUS_BOX_NOTES_FILE"
}

# nexus_box_link "<field>" "<url>" ["<display text>"] - a linked row. The
# display text defaults to the URL; pass something shorter when the URL itself
# adds nothing (a tag name reads better than the release URL twice).
nexus_box_link() {
  if [ -n "${2:-}" ]; then
    nexus_box_row "${1:-Link}" "[${3:-$2}](${2})"
  fi
}

# nexus_box_details "<summary label>" "<file>" - bounded, redacted, fenced.
# Missing or empty file is a no-op, so call sites need no guard.
nexus_box_details() {
  nexus__label="${1:-Details}"
  nexus__src="${2:-}"
  [ -n "$nexus__src" ] || return 0
  [ -f "$nexus__src" ] || return 0
  [ -s "$nexus__src" ] || return 0
  nexus__total_lines="$(wc -l < "$nexus__src" | tr -d ' ')"
  nexus__total_bytes="$(wc -c < "$nexus__src" | tr -d ' ')"
  {
    echo "<details>"
    echo "<summary>${nexus__label}</summary>"
    echo ""
    echo '```'
    head -n "$NEXUS_EXCERPT_MAX_LINES" "$nexus__src" \
      | head -c "$NEXUS_EXCERPT_MAX_BYTES" \
      | nexus_redact
    if [ "$nexus__total_lines" -gt "$NEXUS_EXCERPT_MAX_LINES" ] || [ "$nexus__total_bytes" -gt "$NEXUS_EXCERPT_MAX_BYTES" ]; then
      echo ""
      echo "... excerpt only: ${nexus__total_lines} line(s) / ${nexus__total_bytes} byte(s) in total. Full text: the run log."
    fi
    echo '```'
    echo "</details>"
    echo ""
  } >> "$NEXUS_BOX_DETAILS_FILE"
}

# nexus_box_text "<summary label>" "<text>" - same bounding, from a string.
nexus_box_text() {
  nexus__tmp_text="${NEXUS_TMP}/nexus-text-$$.txt"
  printf '%s\n' "${2:-}" > "$nexus__tmp_text"
  nexus_box_details "${1:-Details}" "$nexus__tmp_text"
  rm -f "$nexus__tmp_text"
}

# nexus_box_failure - render the captured cause, if any. Returns 0 when a cause
# was rendered, 1 when there was nothing to render (so the caller can pick its
# status line from the same test). Reads $NEXUS_CAUSE_FILE; set that variable to
# read a record from somewhere else.
nexus_box_failure() {
  nexus__cause="$NEXUS_CAUSE_FILE"
  if [ ! -s "$nexus__cause" ]; then
    return 1
  fi
  nexus__step="$(grep -m1 '^step=' "$nexus__cause" | cut -d= -f2- || true)"
  nexus__rc_read="$(grep -m1 '^exit_code=' "$nexus__cause" | cut -d= -f2- || true)"
  nexus__cmd="$(grep -m1 '^command=' "$nexus__cause" | cut -d= -f2- || true)"
  nexus__msg="$(grep -m1 '^message=' "$nexus__cause" | cut -d= -f2- || true)"
  nexus_box_row "Failed step" "${nexus__step:-unknown}"
  nexus_box_row "Exit code" "${nexus__rc_read:-unknown}"
  if [ -n "$nexus__msg" ]; then
    nexus_box_row "Cause" "$(printf '%s' "$nexus__msg" | cut -c1-300)"
  elif [ -n "$nexus__cmd" ]; then
    nexus_box_row "Failing command" "\`$(printf '%s' "$nexus__cmd" | cut -c1-160)\`"
  fi
  # Prefer the captured stderr; fall back to the whole record when the step ran
  # in metadata-only mode and there is no stderr block.
  nexus__stderr_excerpt="${NEXUS_TMP}/nexus-cause-excerpt.txt"
  sed -n '/^stderr<<NEXUS_EOF$/,/^NEXUS_EOF$/p' "$nexus__cause" \
    | sed -e '/^stderr<<NEXUS_EOF$/d' -e '/^NEXUS_EOF$/d' > "$nexus__stderr_excerpt" 2>/dev/null || true
  if [ -s "$nexus__stderr_excerpt" ]; then
    nexus_box_details "First error - captured before the failure propagated" "$nexus__stderr_excerpt"
  else
    nexus_box_details "Failure record - captured before the failure propagated" "$nexus__cause"
  fi
  return 0
}

# nexus_box_end - assemble, cap, flush once. Safe to call twice.
nexus_box_end() {
  [ -n "$NEXUS_BOX_FILE" ] || return 0
  [ "$NEXUS_BOX_FLUSHED" = "0" ] || return 0
  {
    echo ""
    echo "---"
    echo ""
    echo "### ${NEXUS_BOX_TITLE}"
    echo ""
    if [ -s "$NEXUS_BOX_STATUS_FILE" ]; then
      cat "$NEXUS_BOX_STATUS_FILE"
    fi
    if [ -s "$NEXUS_BOX_ROWS_FILE" ]; then
      echo "| Field | Value |"
      echo "| --- | --- |"
      cat "$NEXUS_BOX_ROWS_FILE"
      echo ""
    fi
    if [ "$NEXUS_BOX_ROWS_DROPPED" -gt 0 ]; then
      echo "> ${NEXUS_BOX_ROWS_DROPPED} further row(s) omitted - the box shows the first ${NEXUS_ROWS_MAX}. Full detail: the run log."
      echo ""
    fi
    if [ -s "$NEXUS_BOX_NOTES_FILE" ]; then
      cat "$NEXUS_BOX_NOTES_FILE"
    fi
    if [ -s "$NEXUS_BOX_DETAILS_FILE" ]; then
      cat "$NEXUS_BOX_DETAILS_FILE"
    fi
  } > "$NEXUS_BOX_FILE"
  nexus__truncate_box "$NEXUS_BOX_FILE"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$NEXUS_BOX_FILE" >> "$GITHUB_STEP_SUMMARY"
  else
    cat "$NEXUS_BOX_FILE"
  fi
  NEXUS_BOX_FLUSHED="1"
}

# Cut $1 in place at NEXUS_BOX_MAX_BYTES, closing anything the cut left open.
nexus__truncate_box() {
  nexus__target="$1"
  [ -f "$nexus__target" ] || return 0
  nexus__bytes="$(wc -c < "$nexus__target" | tr -d ' ')"
  if [ "$nexus__bytes" -le "$NEXUS_BOX_MAX_BYTES" ]; then
    return 0
  fi
  nexus__cut="${nexus__target}.cut"
  head -c "$NEXUS_BOX_MAX_BYTES" "$nexus__target" > "$nexus__cut"
  # drop the (possibly partial) final line
  sed -i '$d' "$nexus__cut"
  nexus__fences="$(grep -c '^```$' "$nexus__cut" || true)"
  if [ $(( nexus__fences % 2 )) -eq 1 ]; then
    printf '```\n' >> "$nexus__cut"
  fi
  nexus__det_open="$(grep -c '<details' "$nexus__cut" || true)"
  nexus__det_close="$(grep -c '</details>' "$nexus__cut" || true)"
  while [ "$nexus__det_open" -gt "$nexus__det_close" ]; do
    printf '</details>\n' >> "$nexus__cut"
    nexus__det_close=$(( nexus__det_close + 1 ))
  done
  {
    echo ""
    echo "> :warning: Box truncated at ${NEXUS_BOX_MAX_BYTES} of ${nexus__bytes} bytes. Full detail: the run log."
  } >> "$nexus__cut"
  mv "$nexus__cut" "$nexus__target"
}

# nexus_run_url - link back to this run, for the box footer.
nexus_run_url() {
  if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    printf 'https://github.com/%s/actions/runs/%s' "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  fi
}
