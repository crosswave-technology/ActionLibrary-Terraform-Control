#!/usr/bin/env bash
set -euo pipefail

command="${COMMAND:-plan}"
working_dir="${WORKING_DIRECTORY:-.}"
plan_add="${PLAN_ADD:-}"
plan_change="${PLAN_CHANGE:-}"
plan_destroy="${PLAN_DESTROY:-}"
plan_exit_code="${PLAN_EXIT_CODE:-}"
plan_has_changes="${PLAN_HAS_CHANGES:-}"
plan_text_file="${PLAN_TEXT_FILE:-}"
plan_log_file="${PLAN_LOG_FILE:-}"
apply_outcome="${APPLY_OUTCOME:-}"
apply_exit_code="${APPLY_EXIT_CODE:-}"
apply_log_file="${APPLY_LOG_FILE:-}"
emit_raw_plan="${EMIT_RAW_PLAN:-true}"
if [ "${EMIT_FULL_PLAN:-false}" = "true" ]; then
  emit_raw_plan="true"
fi
max_lines_per_resource="${SUMMARY_MAX_LINES:-80}"
max_log_chars=30000

summary_file="${RUNNER_TEMP:-/tmp}/terraform-summary.md"
comment_file="${RUNNER_TEMP:-/tmp}/terraform-comment.md"
: > "$summary_file"
: > "$comment_file"

path_label="$working_dir"
if [ -z "$path_label" ] || [ "$path_label" = "." ]; then
  path_label="root"
fi
comment_slug="$(printf '%s' "$path_label" | tr '/\\' '-' | tr -c 'A-Za-z0-9._-' '-' | tr -s '-')"
# Determine section ID and whether to use consolidated comment
comment_section_id="${{ inputs.comment-section-id }}"
if [ -z "$comment_section_id" ]; then
  comment_section_id="plan-${comment_slug}"
fi
section_open="<!-- section:${comment_section_id} -->"
section_close="<!-- /section:${comment_section_id} -->"
consolidated_marker="<!-- crosswave-terraform-report -->"
comment_marker="${consolidated_marker}"
run_url="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

validate_exit="${VALIDATE_EXIT_CODE:-}"
validate_outcome="${VALIDATE_OUTCOME:-}"
validate_log="${VALIDATE_LOG_FILE:-}"
validate_on_plan="${VALIDATE_ON_PLAN:-true}"
validate_status="skipped"
validate_icon=":fast_forward:"
validate_detail="skipped"
if [ "$command" = "plan" ] && [ "$validate_on_plan" = "true" ] && { [ -n "$validate_exit" ] || [ -n "$validate_outcome" ]; }; then
  if [ "$validate_exit" = "0" ] || [ "$validate_outcome" = "success" ]; then
    validate_status="passed"
    validate_icon=":heavy_check_mark:"
    validate_detail="required"
  else
    validate_status="failed"
    validate_icon=":x:"
    validate_detail="required"
  fi
fi

checkov_enabled="${CHECKOV_ENABLED:-false}"
checkov_exit="${CHECKOV_EXIT_CODE:-}"
checkov_outcome="${CHECKOV_OUTCOME:-}"
checkov_log="${CHECKOV_LOG_FILE:-}"
checkov_gate_failed="${CHECKOV_GATE_FAILED:-false}"
checkov_gate_severities="${CHECKOV_GATE_SEVERITIES:-}"
checkov_status="skipped"
checkov_icon=":fast_forward:"
checkov_detail="disabled"
show_checks_table="false"
checkov_summary_file="${RUNNER_TEMP:-/tmp}/checkov-summary.md"
checkov_comment_file="${RUNNER_TEMP:-/tmp}/checkov-comment.txt"
: > "$checkov_summary_file"
: > "$checkov_comment_file"

if [ "$command" = "plan" ] && { [ "$validate_on_plan" = "true" ] || [ "$checkov_enabled" = "true" ]; }; then
  show_checks_table="true"
fi

if [ "$command" = "plan" ] && [ "$checkov_enabled" = "true" ]; then
  checkov_detail="advisory"
  if [ -n "$checkov_log" ] && [ -f "$checkov_log" ]; then
    CHECKOV_LOG_FILE="$checkov_log" CHECKOV_SUMMARY_FILE="$checkov_summary_file" CHECKOV_COMMENT_FILE="$checkov_comment_file" node <<'NODE'
    const fs = require("fs");
    const logPath = process.env.CHECKOV_LOG_FILE;
    const summaryPath = process.env.CHECKOV_SUMMARY_FILE;
    const commentPath = process.env.CHECKOV_COMMENT_FILE;
    if (!logPath || !fs.existsSync(logPath)) {
      process.exit(0);
    }
    let data;
    try {
      data = JSON.parse(fs.readFileSync(logPath, "utf8"));
    } catch (error) {
      fs.writeFileSync(summaryPath, "Unable to parse Checkov JSON output.");
      fs.writeFileSync(commentPath, "parse_error");
      process.exit(0);
    }
    const results = data && data.results ? data.results : data;
    const failed = Array.isArray(results.failed_checks) ? results.failed_checks : [];
    const passed = Array.isArray(results.passed_checks) ? results.passed_checks : [];
    const skipped = Array.isArray(results.skipped_checks) ? results.skipped_checks : [];
    const severityOrder = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFO", "UNKNOWN"];
    const countSeverities = (checks) => {
      const counts = { CRITICAL: 0, HIGH: 0, MEDIUM: 0, LOW: 0, INFO: 0, UNKNOWN: 0 };
      (checks || []).forEach((check) => {
        const raw = (check.severity || check.severity_level || "UNKNOWN");
        const key = counts.hasOwnProperty(String(raw).toUpperCase()) ? String(raw).toUpperCase() : "UNKNOWN";
        counts[key] += 1;
      });
      return counts;
    };
    const failedCounts = countSeverities(failed);
    const passedCounts = countSeverities(passed);
    const skippedCounts = countSeverities(skipped);
    const lines = [
      "| Severity | Passed | Failed | Skipped |",
      "| --- | --- | --- | --- |",
    ];
    severityOrder.forEach((level) => {
      lines.push(`| ${level} | ${passedCounts[level]} | ${failedCounts[level]} | ${skippedCounts[level]} |`);
    });
    let details = [];
    if (failed.length) {
      const limit = 50;
      details.push("");
      details.push("<details>");
      details.push("<summary>Failed checks</summary>");
      details.push("");
      failed.slice(0, limit).forEach((check) => {
        const id = String(check.check_id || "UNKNOWN").trim();
        const name = String(check.check_name || "Unnamed check").trim();
        const severity = String(check.severity || check.severity_level || "UNKNOWN").toUpperCase();
        const resource = String(check.resource || "n/a").trim();
        details.push(`- ${id} (${severity}) - ${name} - ${resource}`);
      });
      if (failed.length > limit) {
        details.push(`- ... (${failed.length - limit} more)`);
      }
      details.push("</details>");
    }
    if (skipped.length) {
      details.push("");
      details.push("<details>");
      details.push("<summary>Skipped checks</summary>");
      details.push("");
      skipped.slice(0, 25).forEach((check) => {
        const id = String(check.check_id || "UNKNOWN").trim();
        const name = String(check.check_name || "Unnamed check").trim();
        details.push(`- ${id} - ${name}`);
      });
      if (skipped.length > 25) {
        details.push(`- ... (${skipped.length - 25} more)`);
      }
      details.push("</details>");
    }
    fs.writeFileSync(summaryPath, lines.concat(details).join("\n") + "\n");
    const commentLine = severityOrder.map((level) => `${level}:${failedCounts[level]}`).join(" ");
    fs.writeFileSync(commentPath, commentLine + "\n");
NODE
  fi
  counts_line="$(tr -d '\n' < "$checkov_comment_file" 2>/dev/null || true)"
  if [ -n "$counts_line" ] && [ "$counts_line" != "parse_error" ]; then
    checkov_detail="$counts_line"
  elif [ "$counts_line" = "parse_error" ]; then
    checkov_detail="parse_error"
  fi
  if [ "$checkov_gate_failed" = "true" ]; then
    checkov_status="failed"
    checkov_icon=":x:"
    if [ -n "$checkov_gate_severities" ]; then
      checkov_detail="blocked (${checkov_gate_severities})${checkov_detail:+ - ${checkov_detail}}"
    else
      checkov_detail="blocked${checkov_detail:+ - ${checkov_detail}}"
    fi
  elif [ -n "$checkov_exit" ] && [ "$checkov_exit" != "0" ]; then
    checkov_status="failures"
    checkov_icon=":warning:"
    checkov_detail="${checkov_detail:-advisory}"
  else
    checkov_status="passed"
    checkov_icon=":heavy_check_mark:"
    checkov_detail="${checkov_detail:-advisory}"
  fi
fi

if [ -z "$plan_text_file" ] || [ ! -f "$plan_text_file" ]; then
  if [ -f "terraform.plan.txt" ]; then
    plan_text_file="$(pwd)/terraform.plan.txt"
  fi
fi

if [ -z "$plan_text_file" ] || [ ! -f "$plan_text_file" ]; then
  if [ -f "terraform.plan" ]; then
    terraform show -no-color "terraform.plan" > "terraform.plan.txt" || true
    if [ -f "terraform.plan.txt" ]; then
      plan_text_file="$(pwd)/terraform.plan.txt"
    fi
  fi
fi

if [ -f "$plan_text_file" ]; then
  plan_line="$(grep -E 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy\\.' "$plan_text_file" | tail -n 1 || true)"
  if [ -n "$plan_line" ]; then
    plan_add="$(printf '%s' "$plan_line" | sed -E 's/.*Plan: ([0-9]+) to add, ([0-9]+) to change, ([0-9]+) to destroy.*/\\1/')"
    plan_change="$(printf '%s' "$plan_line" | sed -E 's/.*Plan: ([0-9]+) to add, ([0-9]+) to change, ([0-9]+) to destroy.*/\\2/')"
    plan_destroy="$(printf '%s' "$plan_line" | sed -E 's/.*Plan: ([0-9]+) to add, ([0-9]+) to change, ([0-9]+) to destroy.*/\\3/')"
  fi
fi

plan_add="${plan_add:-?}"
plan_change="${plan_change:-?}"
plan_destroy="${plan_destroy:-?}"

if [ "$command" = "plan" ]; then
  header="### Terraform plan"
  has_plan_summary="false"
  has_errors="false"
  if [ -f "$plan_text_file" ]; then
    if grep -q 'Plan:' "$plan_text_file"; then
      has_plan_summary="true"
    fi
    if grep -q '^Error:' "$plan_text_file"; then
      if grep -v '^Error: Process completed with exit code' "$plan_text_file" | grep -q '^Error:'; then
        has_errors="true"
      fi
    fi
  fi
  if [ "$validate_status" = "failed" ]; then
    status_line=":x: Terraform plan - blocked (validation failed)"
  elif [ "$plan_has_changes" = "true" ] || { [ "$plan_exit_code" = "1" ] && [ "$has_plan_summary" = "true" ] && [ "$has_errors" = "false" ]; }; then
    status_line=":heavy_check_mark: Terraform plan - changes detected (required)"
  elif [ "$plan_exit_code" = "1" ]; then
    status_line=":x: Terraform plan - failed (required)"
  else
    status_line=":heavy_check_mark: Terraform plan - no changes (required)"
  fi
else
  header="### Terraform apply"
  if [ "$apply_outcome" = "failure" ] || { [ -n "$apply_exit_code" ] && [ "$apply_exit_code" != "0" ]; }; then
    status_line=":x: Terraform apply - failed"
  else
    status_line=":heavy_check_mark: Terraform apply - completed"
  fi
fi

apply_changes_file="${RUNNER_TEMP:-/tmp}/terraform-apply-changes.md"
apply_errors_file="${RUNNER_TEMP:-/tmp}/terraform-apply-errors.md"
apply_counts_file="${RUNNER_TEMP:-/tmp}/terraform-apply-counts.txt"
apply_applied="0"
apply_failed="0"

if [ "$command" = "apply" ]; then
  if [ -z "$apply_log_file" ] || [ ! -f "$apply_log_file" ]; then
    if [ -f "${RUNNER_TEMP:-/tmp}/terraform-apply.log" ]; then
      apply_log_file="${RUNNER_TEMP:-/tmp}/terraform-apply.log"
    elif [ -f "terraform-apply.log" ]; then
      apply_log_file="$(pwd)/terraform-apply.log"
    fi
  fi

  if [ -n "$apply_log_file" ] && [ -f "$apply_log_file" ]; then
    APPLY_LOG_FILE="$apply_log_file" APPLY_CHANGES_FILE="$apply_changes_file" APPLY_ERRORS_FILE="$apply_errors_file" APPLY_COUNTS_FILE="$apply_counts_file" MAX_LINES="$max_lines_per_resource" node <<'NODE'
    const fs = require("fs");
    const logPath = process.env.APPLY_LOG_FILE;
    const changesPath = process.env.APPLY_CHANGES_FILE;
    const errorsPath = process.env.APPLY_ERRORS_FILE;
    const countsPath = process.env.APPLY_COUNTS_FILE;
    const maxLines = Math.max(parseInt(process.env.MAX_LINES || "80", 10), 1);

    const writeFile = (path, content) => {
      if (path) {
        fs.writeFileSync(path, content);
      }
    };

    if (!logPath || !fs.existsSync(logPath)) {
      writeFile(changesPath, "");
      writeFile(errorsPath, "");
      writeFile(countsPath, "applied=0\nfailed=0\n");
      process.exit(0);
    }

    const raw = fs.readFileSync(logPath, "utf8");
    const lines = raw.split(/\r?\n/);
    const allowed = /^(Creating|Modifying|Destroying|Recreating|Creation complete|Modifications complete|Destruction complete|Recreation complete|Still creating|Still modifying|Still destroying|Reading|Read complete|Refreshing state|Refresh complete)/;

    const resourceLines = new Map();
    const resourceOrder = [];
    const errorBlocks = new Map();
    const errorOrder = [];

    const escapeHtml = (value) => {
      return value
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
    };

    const addResourceLine = (address, line) => {
      if (!resourceLines.has(address)) {
        resourceLines.set(address, []);
        resourceOrder.push(address);
      }
      resourceLines.get(address).push(line);
    };

    lines.forEach((line) => {
      const match = line.match(/^([^\s].*?):\s+(.*)$/);
      if (!match) {
        return;
      }
      const address = match[1].trim();
      const message = match[2].trim();
      if (!allowed.test(message)) {
        return;
      }
      addResourceLine(address, line);
    });

    let currentError = null;
    const flushError = () => {
      if (!currentError || currentError.length === 0) {
        return;
      }
      let address = "apply error";
      for (const line of currentError) {
        const match = line.match(/^\s*with\s+([^,]+),/);
        if (match) {
          address = match[1].trim();
          break;
        }
      }
      if (!errorBlocks.has(address)) {
        errorBlocks.set(address, []);
        errorOrder.push(address);
      }
      errorBlocks.get(address).push(currentError);
      currentError = null;
    };

    lines.forEach((line) => {
      if (line.startsWith("Error:")) {
        flushError();
        currentError = [line];
        return;
      }
      if (currentError) {
        currentError.push(line);
      }
    });
    flushError();

    const renderDetails = (icon, address, contentLines) => {
      let linesToShow = contentLines.slice();
      let truncated = false;
      if (linesToShow.length > maxLines) {
        linesToShow = linesToShow.slice(0, maxLines);
        truncated = true;
      }
      let body = linesToShow.join("\n").trim();
      if (!body) {
        body = "(no apply output captured)";
      }
      if (truncated) {
        body += `\n\n... (${contentLines.length - maxLines} more lines)`;
      }
      return [
        "<details>",
        `<summary>${icon} ${address}</summary>`,
        "<pre>",
        escapeHtml(body),
        "</pre>",
        "</details>",
        "",
      ].join("\n");
    };

    const failedSet = new Set(errorOrder);
    const successAddresses = resourceOrder.filter((address) => !failedSet.has(address));

    const successOutput = successAddresses
      .map((address) => renderDetails(":heavy_minus_sign:", address, resourceLines.get(address) || []))
      .join("\n");

    const errorOutput = errorOrder
      .map((address) => {
        const blocks = errorBlocks.get(address) || [];
        const flattened = [];
        blocks.forEach((block, index) => {
          if (index > 0) {
            flattened.push("");
          }
          flattened.push(...block);
        });
        return renderDetails(":x:", address, flattened);
      })
      .join("\n");

    writeFile(changesPath, successOutput ? successOutput + "\n" : "");
    writeFile(errorsPath, errorOutput ? errorOutput + "\n" : "");
    writeFile(countsPath, `applied=${successAddresses.length}\nfailed=${errorOrder.length}\n`);
NODE
  fi

  if [ -f "$apply_counts_file" ]; then
    apply_applied="$(grep -E '^applied=' "$apply_counts_file" | head -n 1 | cut -d= -f2)"
    apply_failed="$(grep -E '^failed=' "$apply_counts_file" | head -n 1 | cut -d= -f2)"
  fi
  apply_applied="${apply_applied:-0}"
  apply_failed="${apply_failed:-0}"
fi

{
  echo "$header"
  echo ""
  echo "$status_line"
  echo ""
  if [ "$command" = "plan" ] && [ "$show_checks_table" = "true" ]; then
    echo "| Check | Status | Details |"
    echo "| --- | --- | --- |"
    echo "| Terraform validate | ${validate_icon} ${validate_status} | ${validate_detail} |"
    echo "| Checkov scan | ${checkov_icon} ${checkov_status} | ${checkov_detail} |"
    echo ""
  fi
  if [ "$command" = "plan" ]; then
    echo "| Add | Change | Destroy |"
    echo "| --- | --- | --- |"
    echo "| ${plan_add} | ${plan_change} | ${plan_destroy} |"
  else
    echo "| Applied | Failed |"
    echo "| --- | --- |"
    echo "| ${apply_applied} | ${apply_failed} |"
  fi
} >> "$summary_file"

if [ "$command" = "plan" ]; then
  # Build the section content (not the outer comment structure)
  section_content_file="${RUNNER_TEMP:-/tmp}/terraform-section.md"
  : > "$section_content_file"

  # Status badge
  if [ "$validate_status" = "failed" ]; then
    plan_status_line="ðŸ”´ **Plan** â€” blocked (validation failed)"
  elif [ "$plan_exit_code" = "1" ]; then
    plan_status_line="ðŸ”´ **Plan** â€” failed"
  elif [ "$plan_has_changes" = "true" ]; then
    plan_status_line="ðŸŸ¡ **Plan** â€” changes pending"
  else
    plan_status_line="ðŸŸ¢ **Plan** â€” no changes"
  fi

  {
    echo "#### ${path_label}"
    echo ""
    echo "$plan_status_line &nbsp;|&nbsp; Run: [${GITHUB_RUN_ID}](${run_url})"
    echo ""
    # Resource counts table
    echo "| ðŸŸ¢ Add | ðŸŸ¡ Change | ðŸ”´ Destroy |"
    echo "| --- | --- | --- |"
    echo "| ${plan_add} | ${plan_change} | ${plan_destroy} |"
    # Checks table
    if [ "$show_checks_table" = "true" ]; then
      echo ""
      echo "| Check | Status |"
      echo "| --- | --- |"
      echo "| Validate | ${validate_icon} ${validate_status} |"
      echo "| Checkov | ${checkov_icon} ${checkov_status} |"
    fi
  } >> "$section_content_file"

  # Error block when plan failed â€” uses extracted errors file
  error_file_path="${{ steps.plan.outputs.plan_error_file }}"
  error_count_val="${{ steps.plan.outputs.plan_error_count }}"
  if [ -n "$error_count_val" ] && [ "$error_count_val" != "0" ] && [ -n "$error_file_path" ] && [ -f "$error_file_path" ] && [ -s "$error_file_path" ]; then
    {
      echo ""
      echo "<details>"
      echo "<summary>ðŸ”´ <strong>Plan errors (${error_count_val})</strong></summary>"
      echo ""
      echo '```'
      head -c 4000 "$error_file_path"
      echo '```'
      echo "</details>"
    } >> "$section_content_file"
  elif [ -n "$plan_log_file" ] && [ -f "$plan_log_file" ] && [ "${plan_exit_code:-}" = "1" ]; then
    {
      echo ""
      echo "<details>"
      echo "<summary>ðŸ”´ <strong>Plan error output</strong></summary>"
      echo ""
      echo '```'
      head -c 3000 "$plan_log_file"
      echo '```'
      echo "</details>"
    } >> "$section_content_file"
  fi

  # Checkov findings summary
  if [ -s "$checkov_summary_file" ]; then
    {
      echo ""
      echo "<details>"
      echo "<summary>${checkov_icon} <strong>Checkov findings</strong></summary>"
      echo ""
      cat "$checkov_summary_file"
      echo "</details>"
    } >> "$section_content_file"
  fi

  # Build the full comment_file with consolidated structure
  {
    echo "${consolidated_marker}"
    echo "## ðŸ” Terraform PR Report"
    echo ""
    echo "_Last updated: $(date -u '+%Y-%m-%dT%H:%M:%SZ') by run [${GITHUB_RUN_ID}](${run_url})_"
    echo ""
    echo "${section_open}"
    cat "$section_content_file"
    echo "${section_close}"
  } > "$comment_file"
fi

if [ "$command" = "apply" ]; then
  apply_error_excerpt=""
  if [ -n "$apply_log_file" ] && [ -f "$apply_log_file" ]; then
    apply_log_excerpt="${RUNNER_TEMP:-/tmp}/terraform-apply-error.log"
    log_size=$(wc -c < "$apply_log_file" | tr -d ' ')
    if [ "$log_size" -gt "$max_log_chars" ]; then
      head -c "$max_log_chars" "$apply_log_file" > "$apply_log_excerpt"
      printf "\n\n...truncated (%s chars)\n" "$log_size" >> "$apply_log_excerpt"
    else
      cp "$apply_log_file" "$apply_log_excerpt"
    fi
    apply_error_excerpt="$apply_log_excerpt"
  fi

  {
    echo ""
    if [ -s "$apply_errors_file" ]; then
      echo "### Apply failures"
      echo ""
      cat "$apply_errors_file"
    elif [ -n "$apply_error_excerpt" ] && [ -f "$apply_error_excerpt" ] && { [ -n "$apply_exit_code" ] && [ "$apply_exit_code" != "0" ]; }; then
      echo "### Apply failures"
      echo ""
      echo "<details>"
      echo "<summary>:x: apply error</summary>"
      echo ""
      echo '```'
      cat "$apply_error_excerpt"
      echo '```'
      echo "</details>"
      echo ""
    fi
    echo "<details open>"
    echo "<summary><strong>Applied resources</strong></summary>"
    echo ""
    if [ -s "$apply_changes_file" ]; then
      cat "$apply_changes_file"
    else
      echo "_No applied resources detected._"
    fi
    echo ""
    echo "</details>"
  } >> "$summary_file"

  cat "$summary_file" >> "$GITHUB_STEP_SUMMARY"
  echo "comment_file=$comment_file" >> "$GITHUB_OUTPUT"
  echo "comment_marker=$comment_marker" >> "$GITHUB_OUTPUT"
  exit 0
fi

if [ "$command" = "plan" ] && [ "$validate_status" = "failed" ] && [ -n "$validate_log" ] && [ -f "$validate_log" ]; then
  {
    echo ""
    echo "<details>"
    echo "<summary>Terraform validate output</summary>"
    echo ""
    echo '```'
    cat "$validate_log"
    echo '```'
    echo "</details>"
  } >> "$summary_file"
fi

plan_error_excerpt=""
if [ -n "$plan_log_file" ] && [ -f "$plan_log_file" ]; then
  plan_log_excerpt="${RUNNER_TEMP:-/tmp}/terraform-plan-error.log"
  log_size=$(wc -c < "$plan_log_file" | tr -d ' ')
  if [ "$log_size" -gt "$max_log_chars" ]; then
    head -c "$max_log_chars" "$plan_log_file" > "$plan_log_excerpt"
    printf "\n\n...truncated (%s chars)\n" "$log_size" >> "$plan_log_excerpt"
  else
    cp "$plan_log_file" "$plan_log_excerpt"
  fi
  plan_error_excerpt="$plan_log_excerpt"
fi

if [ "$command" = "plan" ] && [ "$plan_exit_code" = "1" ] && [ -n "$plan_error_excerpt" ] && [ -f "$plan_error_excerpt" ]; then
  {
    echo ""
    echo "<details>"
    echo "<summary>Terraform plan error output</summary>"
    echo ""
    echo '```'
    cat "$plan_error_excerpt"
    echo '```'
    echo "</details>"
  } >> "$summary_file"
  {
    echo ""
    echo "<details>"
    echo "<summary>Terraform plan error output</summary>"
    echo ""
    echo '```'
    cat "$plan_error_excerpt"
    echo '```'
    echo "</details>"
  } >> "$comment_file"
fi

if [ "$command" = "plan" ] && [ -s "$checkov_summary_file" ]; then
  {
    echo ""
    echo "### Checkov scan"
    echo ""
    cat "$checkov_summary_file"
  } >> "$summary_file"
fi

if [ ! -f "$plan_text_file" ]; then
  {
    echo ""
    echo "_Plan output not available._"
  } >> "$summary_file"
  cat "$summary_file" >> "$GITHUB_STEP_SUMMARY"
  echo "comment_file=$comment_file" >> "$GITHUB_OUTPUT"
  echo "comment_marker=$comment_marker" >> "$GITHUB_OUTPUT"
  exit 0
fi

warnings_file="${RUNNER_TEMP:-/tmp}/terraform-warnings.txt"
awk '
  BEGIN { in_warning = 0 }
  /^Warning:/ {
    if (in_warning) print ""
    in_warning = 1
  }
  in_warning { print }
  in_warning && NF == 0 { in_warning = 0 }
' "$plan_text_file" > "$warnings_file"

if [ -s "$warnings_file" ]; then
  {
    echo ""
    echo "### Warnings"
    echo ""
    echo "<details>"
    echo "<summary>Terraform warnings</summary>"
    echo ""
    echo '```'
    cat "$warnings_file"
    echo '```'
    echo "</details>"
  } >> "$summary_file"
fi

resource_details="${RUNNER_TEMP:-/tmp}/terraform-resource-changes.md"
drift_details="${RUNNER_TEMP:-/tmp}/terraform-resource-drift.md"
: > "$resource_details"
: > "$drift_details"
awk -v plan_out="$resource_details" -v drift_out="$drift_details" -v max_lines="$max_lines_per_resource" '
  function action_for(header) {
    if (header ~ /will be created/) return "add"
    if (header ~ /will be updated in-place/) return "update"
    if (header ~ /will be read during apply/) return "read"
    if (header ~ /must be replaced/ || header ~ /will be replaced/) return "replace"
    if (header ~ /will be destroyed/) return "remove"
    if (header ~ /has been created/) return "add"
    if (header ~ /has been updated/ || header ~ /has been changed/) return "update"
    if (header ~ /has been deleted/) return "remove"
    return "unknown"
  }
  function icon_for(action) {
    if (action == "add") return ":green_circle:"
    if (action == "update") return ":yellow_circle:"
    if (action == "replace") return ":orange_circle:"
    if (action == "remove") return ":red_circle:"
    if (action == "read") return ":blue_circle:"
    return ":grey_question:"
  }
  function address_for(header, addr) {
    addr = header
    sub(/ will be created.*/, "", addr)
    sub(/ will be updated in-place.*/, "", addr)
    sub(/ will be read during apply.*/, "", addr)
    sub(/ must be replaced.*/, "", addr)
    sub(/ will be replaced.*/, "", addr)
    sub(/ will be destroyed.*/, "", addr)
    sub(/ has been created.*/, "", addr)
    sub(/ has been updated.*/, "", addr)
    sub(/ has been changed.*/, "", addr)
    sub(/ has been deleted.*/, "", addr)
    gsub(/[[:space:]]+$/, "", addr)
    return addr
  }
  function escape_html(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    return s
  }
  function reset_block() {
    header=""
    block=""
    line_count=0
    total_lines=0
    truncated=0
    current_out=""
  }
  function add_line(line) {
    total_lines++
    if (line_count < max_lines) {
      if (block == "") {
        block = line
      } else {
        block = block "\n" line
      }
      line_count++
    } else {
      truncated=1
    }
  }
  function flush() {
    if (header != "" && current_out != "") {
      print "<details>" >> current_out
      print "<summary>" icon_for(action_for(header)) " " address_for(header) "</summary>" >> current_out
      print "<pre>" >> current_out
      if (block != "") {
        print escape_html(block) >> current_out
      } else {
        print "(no attribute changes detected)" >> current_out
      }
      if (truncated) {
        print "\n... (" (total_lines - max_lines) " more lines)" >> current_out
      }
      print "</pre>" >> current_out
      print "</details>" >> current_out
      print "" >> current_out
    }
    reset_block()
  }
  BEGIN {
    mode=""
    if (max_lines == "" || max_lines <= 0) max_lines=80
    reset_block()
  }
  /^Note: Objects have changed outside of Terraform/ { if (mode != "drift") { flush(); mode="drift" } }
  /^Terraform detected the following changes made outside of Terraform/ { if (mode != "drift") { flush(); mode="drift" } }
  /^Terraform used the selected providers/ { if (mode == "drift") { flush(); mode="" } }
  /^Terraform will perform the following actions:/ { if (mode != "plan") { flush(); mode="plan" } }
  /^Plan:|^Changes to Outputs:|^No changes\\./ { flush(); exit }
  /^[[:space:]]*# / {
    if (mode == "") { next }
    candidate=$0
    sub(/^[[:space:]]*# /, "", candidate)
    if (candidate ~ /^[(]/) { next }
    flush()
    header=candidate
    current_out=(mode == "drift" ? drift_out : plan_out)
    next
  }
  {
    if (header != "") {
      add_line($0)
    }
  }
  END { flush() }
' "$plan_text_file"

{
  echo ""
  echo "<details>"
  echo "<summary><strong>Drift detected</strong></summary>"
  echo ""
  if [ -s "$drift_details" ]; then
    cat "$drift_details"
  else
    echo "_No drift detected._"
  fi
  echo ""
  echo "</details>"
} >> "$summary_file"

{
  echo ""
  echo "<details open>"
  echo "<summary><strong>Resource changes</strong></summary>"
  echo ""
  if [ -s "$resource_details" ]; then
    cat "$resource_details"
  elif [ "$plan_has_changes" != "true" ]; then
    echo "_No planned resource changes._"
  else
    echo "_Resource changes summary unavailable._"
  fi
  echo ""
  echo "</details>"
} >> "$summary_file"

if [ "$emit_raw_plan" = "true" ]; then
  {
    echo ""
    echo "---"
    echo ""
    echo "<details>"
    echo "<summary>RAW Plan Output</summary>"
    echo ""
    echo '```'
    cat "$plan_text_file"
    echo '```'
    echo "</details>"
  } >> "$summary_file"
fi

cat "$summary_file" >> "$GITHUB_STEP_SUMMARY"
echo "comment_file=$comment_file" >> "$GITHUB_OUTPUT"
echo "comment_marker=$comment_marker" >> "$GITHUB_OUTPUT"