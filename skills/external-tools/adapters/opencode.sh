#!/bin/bash
# opencode.sh — OpenCode CLI adapter for external-tools
#
# Commands:
#   health     Preflight check: binary exists, version, auth status
#   implement  Write code on a worktree via OpenCode (headless run)
#   review     Review code changes (read-only prompt) against a rubric/spec
#
# Usage:
#   opencode.sh health
#   opencode.sh implement --worktree <path> --prompt-file <path> [--attempt N] [--timeout S] [--context-dir <dir>]
#   opencode.sh review   --worktree <path> --rubric-file <path> --spec-file <path> [--attempt N] [--timeout S]
#
# Notes:
#   - Never passes --dangerously-skip-permissions. Headless `run` honors the
#     project's opencode.json permission rules.
#   - Output is consumed as JSONL events; the assistant text is in
#     part.type === "text" → part.text; token counts in step_finish → part.tokens.

set -euo pipefail

# ---------------------------------------------------------------------------
# Source shared helpers
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
TOOL_NAME="opencode"
TOOL_CMD="opencode"
DEFAULT_MODEL="opencode/deepseek-v4-flash"

# ===========================================================================
# health — Preflight check
# ===========================================================================
cmd_health() {
  local status="ready"
  local version="unknown"
  local auth_valid=false

  # Check if opencode binary exists
  if ! command -v "$TOOL_CMD" >/dev/null 2>&1; then
    printf '{"tool":"%s","status":"unavailable","version":"not_installed","auth_valid":false,"model":"%s"}\n' \
      "$TOOL_NAME" "$DEFAULT_MODEL"
    return 0
  fi

  # Get version
  version="$("$TOOL_CMD" --version 2>/dev/null || printf 'unknown')"
  version="$(printf '%s' "$version" | tr -d '\n' | xargs)"

  # Check auth: auth.json exists and is non-empty
  local auth_file="${OPENCODE_AUTH_FILE:-${HOME}/.local/share/opencode/auth.json}"
  if [[ -s "$auth_file" ]]; then
    auth_valid=true
  fi

  if [[ "$auth_valid" == "false" ]]; then
    status="unavailable"
  fi

  # Emit JSON — use jq if available for proper escaping, else manual
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg tool "$TOOL_NAME" \
      --arg status "$status" \
      --arg version "$version" \
      --argjson auth_valid "$auth_valid" \
      --arg model "$DEFAULT_MODEL" \
      '{tool: $tool, status: $status, version: $version, auth_valid: $auth_valid, model: $model}'
  else
    printf '{"tool":"%s","status":"%s","version":"%s","auth_valid":%s,"model":"%s"}\n' \
      "$TOOL_NAME" "$status" "$version" "$auth_valid" "$DEFAULT_MODEL"
  fi
}

# ===========================================================================
# run_opencode — Shared headless invocation
#   Usage: run_opencode <stdout_file> <stderr_file> <worktree> <prompt>
# ===========================================================================
run_opencode() {
  local stdout_file="$1"
  local stderr_file="$2"
  local worktree="$3"
  local prompt="$4"

  local model="${OPENCODE_MODEL:-$DEFAULT_MODEL}"
  printf '%s' "$prompt" | safe_invoke "$XT_TIMEOUT" "$stdout_file" "$stderr_file" \
    "$TOOL_CMD" run --format json -m "$model" --dir "$worktree" -
}

# ===========================================================================
# implement — Write code on a worktree
# ===========================================================================
cmd_implement() {
  parse_args "$@"

  # Validate required arguments
  if [[ -z "$XT_WORKTREE" ]]; then
    printf 'Error: --worktree is required for implement\n' >&2
    return 1
  fi
  if [[ -z "$XT_PROMPT_FILE" ]]; then
    printf 'Error: --prompt-file is required for implement\n' >&2
    return 1
  fi
  if [[ ! -d "$XT_WORKTREE" ]]; then
    printf 'Error: worktree directory does not exist: %s\n' "$XT_WORKTREE" >&2
    return 1
  fi
  if [[ ! -f "$XT_PROMPT_FILE" ]]; then
    printf 'Error: prompt file does not exist: %s\n' "$XT_PROMPT_FILE" >&2
    return 1
  fi

  # Create secure tmp dir for capturing output
  local tmp_dir
  tmp_dir="$(create_secure_tmp)"
  local stdout_file="${tmp_dir}/stdout.jsonl"
  local stderr_file="${tmp_dir}/stderr.log"

  local prompt_content
  prompt_content="$(cat "$XT_PROMPT_FILE")"

  # Record start time
  local start_time
  start_time="$(date +%s)"

  # Invoke opencode headless
  local exit_code=0
  run_opencode "$stdout_file" "$stderr_file" "$XT_WORKTREE" "$prompt_content" \
    || exit_code=$?

  # Calculate duration
  local end_time
  end_time="$(date +%s)"
  local duration=$(( end_time - start_time ))

  # Save raw output to LOG_DIR
  mkdir -p "$LOG_DIR"
  local session_id
  session_id="${TOOL_NAME}-implement-$(date +%Y%m%dT%H%M%S)-$$"
  local raw_log_file="${LOG_DIR}/${session_id}.jsonl"
  if [[ -f "$stdout_file" ]]; then
    cp "$stdout_file" "$raw_log_file"
  fi

  # Handle error
  if [[ "$exit_code" -ne 0 ]]; then
    local error_type
    error_type="$(classify_error "$exit_code" "$stderr_file")"

    local error_json
    error_json="$(emit_error \
      "$TOOL_NAME" \
      "implement" \
      "$DEFAULT_MODEL" \
      "$XT_ATTEMPT" \
      "$exit_code" \
      "$stderr_file" \
      "$duration" \
      "$raw_log_file")"
    log_session "$error_json"
    printf '%s\n' "$error_json"

    rm -rf "$tmp_dir"
    return 1
  fi

  # Success path: stage and commit all changes in worktree
  local branch=""
  local git_sha=""

  if [[ -d "$XT_WORKTREE" ]]; then
    git -C "$XT_WORKTREE" add -A 2>/dev/null || true

    if ! git -C "$XT_WORKTREE" diff --cached --quiet 2>/dev/null; then
      git -C "$XT_WORKTREE" commit -m "feat: opencode implement (attempt ${XT_ATTEMPT})" \
        --author="OpenCode CLI <opencode@opencode.ai>" \
        >/dev/null 2>&1 || true
    fi

    # Verify scope (revert out-of-scope changes if context_dir is set)
    if [[ -n "$XT_CONTEXT_DIR" ]]; then
      if ! verify_scope "$XT_WORKTREE" "$XT_CONTEXT_DIR"; then
        git -C "$XT_WORKTREE" add -A 2>/dev/null || true
        if ! git -C "$XT_WORKTREE" diff --cached --quiet 2>/dev/null; then
          git -C "$XT_WORKTREE" commit -m "fix: revert out-of-scope changes" \
            --author="OpenCode CLI <opencode@opencode.ai>" \
            >/dev/null 2>&1 || true
        fi
      fi
    fi

    branch="$(git -C "$XT_WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    git_sha="$(git -C "$XT_WORKTREE" rev-parse HEAD 2>/dev/null || true)"
  fi

  # Extract cost/stats from JSONL events
  local cost_json
  cost_json="$(extract_cost_opencode "$stdout_file")"

  local files_changed_json
  files_changed_json="$(get_changed_files "$XT_WORKTREE")"

  local diff_stats_json
  diff_stats_json="$(get_diff_stats "$XT_WORKTREE")"

  local result_json
  result_json="$(emit_json \
    "$TOOL_NAME" \
    "implement" \
    "$DEFAULT_MODEL" \
    "$XT_ATTEMPT" \
    "$exit_code" \
    "$branch" \
    "$git_sha" \
    "$files_changed_json" \
    "$diff_stats_json" \
    "$duration" \
    "$cost_json" \
    "$raw_log_file")"

  log_session "$result_json"
  printf '%s\n' "$result_json"

  rm -rf "$tmp_dir"
}

# ===========================================================================
# review — Review code changes (read-only)
# ===========================================================================
cmd_review() {
  parse_args "$@"

  # Validate required arguments
  if [[ -z "$XT_WORKTREE" ]]; then
    printf 'Error: --worktree is required for review\n' >&2
    return 1
  fi
  if [[ -z "$XT_RUBRIC_FILE" ]]; then
    printf 'Error: --rubric-file is required for review\n' >&2
    return 1
  fi
  if [[ -z "$XT_SPEC_FILE" ]]; then
    printf 'Error: --spec-file is required for review\n' >&2
    return 1
  fi
  if [[ ! -d "$XT_WORKTREE" ]]; then
    printf 'Error: worktree directory does not exist: %s\n' "$XT_WORKTREE" >&2
    return 1
  fi
  if [[ ! -f "$XT_RUBRIC_FILE" ]]; then
    printf 'Error: rubric file does not exist: %s\n' "$XT_RUBRIC_FILE" >&2
    return 1
  fi
  if [[ ! -f "$XT_SPEC_FILE" ]]; then
    printf 'Error: spec file does not exist: %s\n' "$XT_SPEC_FILE" >&2
    return 1
  fi

  # Create secure tmp dir
  local tmp_dir
  tmp_dir="$(create_secure_tmp)"
  local stdout_file="${tmp_dir}/stdout.jsonl"
  local stderr_file="${tmp_dir}/stderr.log"

  # Build review prompt from git diff + rubric + spec
  local diff_content
  diff_content="$(git -C "$XT_WORKTREE" diff HEAD 2>/dev/null || true)"
  if [[ -z "$diff_content" ]]; then
    diff_content="$(git -C "$XT_WORKTREE" diff HEAD~1 HEAD 2>/dev/null || true)"
  fi

  local rubric_content
  rubric_content="$(cat "$XT_RUBRIC_FILE")"

  local spec_content
  spec_content="$(cat "$XT_SPEC_FILE")"

  local review_prompt
  review_prompt="$(cat <<'PROMPT_TEMPLATE'
You are a code reviewer. Review the following code changes against the provided rubric and specification.
Do not modify any files — this is a read-only review.

## Git Diff
PROMPT_TEMPLATE
)"
  review_prompt+=$'\n```diff\n'"${diff_content}"$'\n```\n'
  review_prompt+=$'\n## Review Rubric\n'"${rubric_content}"$'\n'
  review_prompt+=$'\n## Specification\n'"${spec_content}"$'\n'
  review_prompt+="$(cat <<'PROMPT_FOOTER'

## Instructions
1. Evaluate each criterion in the rubric against the diff and spec.
2. For each finding, provide:
   - Verdict: PASS or FAIL
   - Classification: BLOCKING or WARNING
   - Citation: file:line reference(s)
   - Explanation: why the finding was made
3. At the end, provide an overall verdict: PASS or FAIL.
   - FAIL if any BLOCKING issue is found.
   - PASS if only WARNING issues or no issues.
4. Output your review as structured JSON with keys: "verdict", "findings" (array), "summary".
PROMPT_FOOTER
)"

  # Record start time
  local start_time
  start_time="$(date +%s)"

  # Invoke opencode headless (read-only by instruction)
  local exit_code=0
  run_opencode "$stdout_file" "$stderr_file" "$XT_WORKTREE" "$review_prompt" \
    || exit_code=$?

  # Calculate duration
  local end_time
  end_time="$(date +%s)"
  local duration=$(( end_time - start_time ))

  # Save raw output to LOG_DIR
  mkdir -p "$LOG_DIR"
  local session_id
  session_id="${TOOL_NAME}-review-$(date +%Y%m%dT%H%M%S)-$$"
  local raw_log_file="${LOG_DIR}/${session_id}.jsonl"
  if [[ -f "$stdout_file" ]]; then
    cp "$stdout_file" "$raw_log_file"
  fi

  # Handle error
  if [[ "$exit_code" -ne 0 ]]; then
    local error_json
    error_json="$(emit_error \
      "$TOOL_NAME" \
      "review" \
      "$DEFAULT_MODEL" \
      "$XT_ATTEMPT" \
      "$exit_code" \
      "$stderr_file" \
      "$duration" \
      "$raw_log_file")"
    log_session "$error_json"
    printf '%s\n' "$error_json"

    rm -rf "$tmp_dir"
    return 1
  fi

  # Extract cost from JSONL events
  local cost_json
  cost_json="$(extract_cost_opencode "$stdout_file")"

  local branch=""
  local git_sha=""
  if [[ -d "$XT_WORKTREE" ]]; then
    branch="$(git -C "$XT_WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    git_sha="$(git -C "$XT_WORKTREE" rev-parse HEAD 2>/dev/null || true)"
  fi

  local result_json
  result_json="$(emit_json \
    "$TOOL_NAME" \
    "review" \
    "$DEFAULT_MODEL" \
    "$XT_ATTEMPT" \
    "$exit_code" \
    "$branch" \
    "$git_sha" \
    "[]" \
    '{"additions": 0, "deletions": 0}' \
    "$duration" \
    "$cost_json" \
    "$raw_log_file")"

  log_session "$result_json"
  printf '%s\n' "$result_json"

  rm -rf "$tmp_dir"
}

# ===========================================================================
# Command dispatch
# ===========================================================================
command="${1:-}"
shift || true

case "$command" in
  health)
    cmd_health
    ;;
  implement)
    cmd_implement "$@"
    ;;
  review)
    cmd_review "$@"
    ;;
  *)
    cat >&2 <<USAGE
Usage: $(basename "$0") <command> [options]

Commands:
  health      Check if OpenCode CLI is installed, authenticated, and ready
  implement   Run OpenCode headless on a worktree to implement changes
  review      Run OpenCode to review code changes (read-only)

Options (implement):
  --worktree <path>       Path to the git worktree (required)
  --prompt-file <path>    Path to the prompt file (required)
  --attempt <N>           Attempt number (default: 1)
  --timeout <seconds>     Timeout in seconds (default: 300)
  --context-dir <dir>     Restrict changes to this directory

Options (review):
  --worktree <path>       Path to the git worktree (required)
  --rubric-file <path>    Path to the review rubric file (required)
  --spec-file <path>      Path to the specification file (required)
  --attempt <N>           Attempt number (default: 1)
  --timeout <seconds>     Timeout in seconds (default: 300)

Environment variables:
  OPENCODE_AUTH_FILE      Path to opencode auth.json (default: ~/.local/share/opencode/auth.json)
  OPENCODE_MODEL          Model to use, provider/model format (default: opencode/deepseek-v4-flash)
USAGE
    exit 1
    ;;
esac