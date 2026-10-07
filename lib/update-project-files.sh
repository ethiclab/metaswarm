#!/usr/bin/env bash
# lib/update-project-files.sh
# Updates metaswarm project files from templates, preserving local edits.
# Usage: update-project-files.sh <project-dir> --platform <claude|codex|gemini|opencode|all> [--dry-run]

# Don't use set -e because we handle return codes explicitly
set -uo pipefail

PROJECT_DIR="${1:?Usage: update-project-files.sh <project-dir> --platform <platform> [--dry-run]}"
shift

PLATFORM="all"
DRY_RUN=false
FORCE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --platform)
      PLATFORM="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    --force)
      FORCE=true; shift ;;
    *) shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$PLUGIN_ROOT/skills/setup/templates"

# Track changes
updates=()
skipped=()
conflicts=()

# Helper: show diff between template and destination
show_diff() {
  local src="$1" dest="$2" label="$3"
  if [ ! -f "$src" ]; then
    echo "  ⚠ Source not found: $src" >&2
    return 1
  fi
  if [ ! -f "$dest" ]; then
    echo "  → $label: NEW FILE (will be created)" >&2
    return 0
  fi
  if diff -u "$dest" "$src" >/dev/null 2>&1; then
    echo "  = $label: already up to date" >&2
    return 2  # no changes
  fi
  echo "  ≠ $label: differs from template" >&2
  if [ "$DRY_RUN" = false ]; then
    diff -u "$dest" "$src" | head -50 || true
  fi
  return 0
}

# Helper: copy template to destination
copy_file() {
  local src="$1" dest="$2" label="$3"
  mkdir -p "$(dirname "$dest")"
  if [ "$DRY_RUN" = false ]; then
    cp "$src" "$dest"
  fi
  updates+=("$label")
}

# Helper: update file with user confirmation
update_with_prompt() {
  local src="$1" dest="$2" label="$3" force="${4:-false}"
  
  show_diff "$src" "$dest" "$label"
  local diff_result=$?
  
  if [ $diff_result -eq 2 ]; then
    skipped+=("$label (up to date)")
    return 0
  fi
  
  # In dry-run or force mode, just report/do the update
  if [ "$DRY_RUN" = true ] || [ "$force" = "true" ] || [ "$FORCE" = "true" ]; then
    copy_file "$src" "$dest" "$label"
    return 0
  fi
  
  # Interactive prompt - only if stdin is a TTY
  if [ -t 0 ]; then
    echo -n "  Update $label? [y/N/d=diff] " >&2
    read -r REPLY
    case "$REPLY" in
      [Yy]*)
        copy_file "$src" "$dest" "$label"
        ;;
      [Dd]*)
        diff -u "$dest" "$src" | less
        update_with_prompt "$src" "$dest" "$label"  # re-prompt after viewing diff
        ;;
      *)
        conflicts+=("$label (kept local)")
        ;;
    esac
  else
    # Non-interactive mode: skip with warning
    conflicts+=("$label (skipped: non-interactive, use --force to auto-update)")
  fi
}

# Update OpenCode files
update_opencode() {
  echo "Checking OpenCode files..."
  
  # opencode.json - always update (structural config)
  update_with_prompt \
    "$TEMPLATE_DIR/opencode.json" \
    "$PROJECT_DIR/opencode.json" \
    "opencode.json" \
    true  # force update for config
  
  # Commands
  local cmds=(
    setup start start-task prime review-design design-review-gate
    plan-review-gate orchestrated-execution self-reflect handoff
    pr-shepherd brainstorm update status create-issue
    handle-pr-comments external-tools-health
  )
  
  for cmd in "${cmds[@]}"; do
    update_with_prompt \
      "$PLUGIN_ROOT/commands/${cmd}.md" \
      "$PROJECT_DIR/.opencode/commands/${cmd}.md" \
      ".opencode/commands/${cmd}.md"
  done
  
  # Agents
  local agents=(
    issue-orchestrator architect-agent product-manager-agent researcher-agent
    cto-agent security-design-agent code-review-agent sre-agent
    metrics-agent slack-coordinator-agent coder-agent pr-shepherd-agent
    release-engineer-agent customer-service-agent test-automator-agent
    security-auditor-agent swarm-coordinator-agent designer-agent
    knowledge-curator-agent
  )
  
  for agent in "${agents[@]}"; do
    update_with_prompt \
      "$PLUGIN_ROOT/agents/${agent}.md" \
      "$PROJECT_DIR/.opencode/agents/${agent}.md" \
      ".opencode/agents/${agent}.md"
  done
  
  # OPENCODE.md - don't force, may have project-specific content
  update_with_prompt \
    "$TEMPLATE_DIR/OPENCODE.md" \
    "$PROJECT_DIR/.opencode/OPENCODE.md" \
    ".opencode/OPENCODE.md"
}

# Update instruction files for other platforms
update_instruction_file() {
  local platform="$1" fname="$2" append_tmpl="$3" full_tmpl="$4"
  local target="$PROJECT_DIR/$fname"
  
  if [ ! -f "$append_tmpl" ]; then
    skipped+=("$fname (append template not found)")
    return
  fi
  
  if [ -f "$target" ]; then
    if grep -q "metaswarm" "$target" 2>/dev/null; then
      update_with_prompt "$append_tmpl" "$target" "$fname"
    else
      update_with_prompt "$full_tmpl" "$target" "$fname"
    fi
  else
    update_with_prompt "$full_tmpl" "$target" "$fname"
  fi
}

# Update .coverage-thresholds.json
update_coverage() {
  local target="$PROJECT_DIR/.coverage-thresholds.json"
  local template="$TEMPLATE_DIR/coverage-thresholds.json"
  
  if [ ! -f "$template" ]; then
    skipped+=(".coverage-thresholds.json (template not found)")
    return
  fi
  
  if [ -f "$target" ]; then
    show_diff "$template" "$target" ".coverage-thresholds.json"
    local diff_result=$?
    
    if [ $diff_result -eq 2 ]; then
      skipped+=(".coverage-thresholds.json (up to date)")
    else if [ "$DRY_RUN" = false ]; then
      # For coverage, we need to preserve threshold/command values
      # Read current values
      local cur_threshold cur_cmd
      if command -v node >/dev/null 2>&1; then
        cur_threshold=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$target')).thresholds?.lines || 100)" 2>/dev/null || echo 100)
        cur_cmd=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$target')).enforcement?.command || 'npm test')" 2>/dev/null || echo "npm test")
      else
        cur_threshold=100
        cur_cmd="npm test"
      fi
      
      # Apply template with current values - use a temp file to avoid quoting issues
      local tmpfile=$(mktemp)
      node -e "
        const fs = require('fs');
        const tmpl = JSON.parse(fs.readFileSync('$template', 'utf-8'));
        tmpl.thresholds.lines = $cur_threshold;
        tmpl.thresholds.branches = $cur_threshold;
        tmpl.thresholds.functions = $cur_threshold;
        tmpl.thresholds.statements = $cur_threshold;
        tmpl.enforcement.command = '$cur_cmd';
        fs.writeFileSync('$tmpfile', JSON.stringify(tmpl, null, 2) + '\n');
      " && mv "$tmpfile" "$target"
      updates+=(".coverage-thresholds.json (preserved threshold: ${cur_threshold}%, command: ${cur_cmd})")
    else
      updates+=(".coverage-thresholds.json (would update, preserving threshold)")
    fi
    fi
  else
    # New file - use defaults
    if [ "$DRY_RUN" = false ]; then
      cp "$template" "$target"
    fi
    updates+=(".coverage-thresholds.json (created)")
  fi
}

# Main
echo "=== metaswarm project update ==="
echo "Project: $PROJECT_DIR"
echo "Platform: $PLATFORM"
[ "$DRY_RUN" = true ] && echo "Mode: DRY RUN (no changes)"
echo ""

case "$PLATFORM" in
  opencode)
    update_opencode
    update_coverage
    ;;
  claude)
    update_instruction_file "claude" "CLAUDE.md" "$TEMPLATE_DIR/CLAUDE-append.md" "$TEMPLATE_DIR/CLAUDE.md"
    update_coverage
    ;;
  codex)
    update_instruction_file "codex" "AGENTS.md" "$TEMPLATE_DIR/AGENTS-append.md" "$TEMPLATE_DIR/AGENTS.md"
    update_coverage
    ;;
  gemini)
    update_instruction_file "gemini" "GEMINI.md" "$TEMPLATE_DIR/GEMINI-append.md" "$TEMPLATE_DIR/GEMINI.md"
    update_coverage
    ;;
  all)
    update_opencode
    update_instruction_file "claude" "CLAUDE.md" "$TEMPLATE_DIR/CLAUDE-append.md" "$TEMPLATE_DIR/CLAUDE.md"
    update_instruction_file "codex" "AGENTS.md" "$TEMPLATE_DIR/AGENTS-append.md" "$TEMPLATE_DIR/AGENTS.md"
    update_instruction_file "gemini" "GEMINI.md" "$TEMPLATE_DIR/GEMINI-append.md" "$TEMPLATE_DIR/GEMINI.md"
    update_coverage
    ;;
  *)
    echo "Unknown platform: $PLATFORM" >&2
    exit 1
    ;;
esac

# Summary
echo ""
echo "=== Summary ==="
if [ ${#updates[@]} -gt 0 ]; then
  echo "Updated:"
  for u in "${updates[@]}"; do echo "  ✓ $u"; done
fi
if [ ${#skipped[@]} -gt 0 ]; then
  echo "Skipped (up to date):"
  for s in "${skipped[@]}"; do echo "  = $s"; done
fi
if [ ${#conflicts[@]} -gt 0 ]; then
  echo "Kept local (not updated):"
  for c in "${conflicts[@]}"; do echo "  → $c"; done
fi

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "DRY RUN complete. Run without --dry-run to apply changes."
fi