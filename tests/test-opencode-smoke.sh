#!/usr/bin/env bash
# tests/test-opencode-smoke.sh
# End-to-end smoke test for OpenCode integration.
# Creates a temp project, generates opencode config, validates output.
#
# Usage: bash tests/test-opencode-smoke.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d /tmp/metaswarm-opencode-test-XXXXXX)
trap "rm -rf '$TMPDIR'" EXIT

echo "=== Test: OpenCode integration smoke test ==="
echo "Temp project: $TMPDIR"
echo ""

# 1. Validate the config template is valid JSON
echo "--- [1/12] Validate templates/opencode.json is valid JSON ---"
node -e "JSON.parse(require('fs').readFileSync('$ROOT/templates/opencode.json','utf-8'))" && echo "  PASS: valid JSON"
echo ""

# 2. Validate referenced files exist in the repo
echo "--- [2/12] Validate referenced files exist in repo ---"
fail=0
for cmd in setup start-task prime review-design design-review-gate orchestrated-execution self-reflect handoff pr-shepherd brainstorm update status handle-pr-comments create-issue external-tools-health; do
  if [ -f "$ROOT/commands/${cmd}.md" ]; then
    echo "  PASS: commands/${cmd}.md exists"
  else
    echo "  FAIL: commands/${cmd}.md missing"
    fail=1
  fi
done
for agent in issue-orchestrator architect-agent product-manager-agent designer-agent security-design-agent cto-agent coder-agent code-review-agent researcher-agent test-automator-agent security-auditor-agent knowledge-curator-agent pr-shepherd-agent release-engineer-agent sre-agent customer-service-agent metrics-agent swarm-coordinator-agent slack-coordinator-agent; do
  if [ -f "$ROOT/agents/${agent}.md" ]; then
    echo "  PASS: agents/${agent}.md exists"
  else
    echo "  FAIL: agents/${agent}.md missing"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1
echo ""

# 3. Run setupProject --opencode via metaswarm CLI
echo "--- [3/12] Generate project files via npx metaswarm setup --opencode ---"
cd "$TMPDIR"
node "$ROOT/cli/metaswarm.js" setup --opencode 2>&1
echo ""

# 4. Validate generated opencode.json
echo "--- [4/12] Validate generated opencode.json ---"
if [ -f "$TMPDIR/opencode.json" ]; then
  node -e "JSON.parse(require('fs').readFileSync('$TMPDIR/opencode.json','utf-8'))" && echo "  PASS: valid JSON"
else
  echo "  FAIL: opencode.json not generated"
  exit 1
fi
echo ""

# 5. Validate referenced {file:...} paths resolve
echo "--- [5/12] Validate {file:...} references resolve ---"
fail=0
for ref in .opencode/commands/setup.md .opencode/commands/start-task.md .opencode/commands/prime.md .opencode/commands/review-design.md .opencode/commands/design-review-gate.md .opencode/commands/orchestrated-execution.md .opencode/commands/self-reflect.md .opencode/commands/handoff.md .opencode/commands/pr-shepherd.md .opencode/commands/brainstorm.md .opencode/commands/update.md .opencode/commands/status.md .opencode/commands/handle-pr-comments.md .opencode/commands/create-issue.md .opencode/commands/external-tools-health.md .opencode/agents/issue-orchestrator.md .opencode/agents/architect-agent.md .opencode/agents/product-manager-agent.md .opencode/agents/designer-agent.md .opencode/agents/security-design-agent.md .opencode/agents/cto-agent.md .opencode/agents/coder-agent.md .opencode/agents/code-review-agent.md .opencode/agents/researcher-agent.md .opencode/agents/test-automator-agent.md .opencode/agents/security-auditor-agent.md .opencode/agents/knowledge-curator-agent.md .opencode/agents/pr-shepherd-agent.md .opencode/agents/release-engineer-agent.md .opencode/agents/sre-agent.md .opencode/agents/customer-service-agent.md .opencode/agents/metrics-agent.md .opencode/agents/swarm-coordinator-agent.md .opencode/agents/slack-coordinator-agent.md .opencode/plugins/metaswarm-session.js .opencode/OPENCODE.md; do
  if [ -f "$TMPDIR/$ref" ]; then
    echo "  PASS: $ref exists"
  else
    echo "  FAIL: $ref missing"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1
echo ""

# 6. Validate template + generated opencode.json are identical (deterministic generation)
echo "--- [6/12] Verify generated config matches template ---"
if diff -q "$ROOT/templates/opencode.json" "$TMPDIR/opencode.json" >/dev/null 2>&1; then
  echo "  PASS: generated config matches template"
else
  echo "  FAIL: generated config differs from template (generation must be deterministic)"
  diff "$ROOT/templates/opencode.json" "$TMPDIR/opencode.json" || true
  exit 1
fi
echo ""

# 6.5 Validate skill discovery (SKILL.md copied into .opencode/skills/)
echo "--- [6.5/12] Validate skill definitions are copied for discovery ---"
skill_count=0
for skill_dir in "$ROOT"/skills/*/; do
  [ -d "$skill_dir" ] || continue
  [ -f "$skill_dir/SKILL.md" ] || continue
  skill_count=$((skill_count + 1))
done
if [ "$skill_count" -gt 0 ]; then
  installed_skills=$(ls -d "$TMPDIR"/.opencode/skills/*/ 2>/dev/null | wc -l | tr -d ' ')
  if [ "$installed_skills" -ge "$skill_count" ]; then
    echo "  PASS: $installed_skills skills copied to .opencode/skills/ (hub has $skill_count)"
  else
    echo "  FAIL: expected $skill_count skills, found $installed_skills"
    exit 1
  fi
else
  echo "  SKIP: no skills found in hub"
fi
echo ""

# 6.6 Validate additive upgrade of an existing opencode.json
echo "--- [6.6/12] Validate additive upgrade of existing opencode.json ---"
UPGRADE_TMP=$(mktemp -d /tmp/metaswarm-opencode-upgrade-XXXXXX)
trap "rm -rf '$TMPDIR' '$UPGRADE_TMP'" EXIT
# Simulate an old install: opencode.json with only 2 commands + 1 custom command
cat > "$UPGRADE_TMP/opencode.json" <<'EOF'
{
  "command": {
    "prime": { "template": "{file:.opencode/commands/prime.md}", "description": "old desc" },
    "my-custom": { "template": "{file:.opencode/commands/my-custom.md}", "description": "user custom" }
  },
  "agent": {}
}
EOF
node "$ROOT/cli/metaswarm.js" setup --opencode >/dev/null 2>&1 || true
if command -v node >/dev/null 2>&1; then
  # Run the merge logic via the shell setup path in the upgrade dir
  UPGRADE_OUT=$(bash "$ROOT/lib/setup-mandatory-files.sh" "$UPGRADE_TMP" 100 "npm test" --platform opencode 2>&1 || true)
  merged=$(node -e "const c=JSON.parse(require('fs').readFileSync('$UPGRADE_TMP/opencode.json','utf-8')); console.log(Object.keys(c.command).length)" 2>/dev/null || echo 0)
  if [ "$merged" -ge 15 ]; then
    echo "  PASS: existing config upgraded to $merged commands"
  else
    echo "  FAIL: expected >= 15 commands after upgrade, found $merged"
    exit 1
  fi
  # Custom entry preserved
  if node -e "const c=JSON.parse(require('fs').readFileSync('$UPGRADE_TMP/opencode.json','utf-8')); if(!c.command['my-custom']) process.exit(1)"; then
    echo "  PASS: user-custom command preserved"
  else
    echo "  FAIL: user-custom command was lost during upgrade"
    exit 1
  fi
else
  echo "  SKIP: node not available for upgrade test"
fi
echo ""

# 7. Smoke test: opencode loads config without errors
echo "--- [7/12] Verify opencode can parse the config ---"
if command -v opencode >/dev/null 2>&1; then
  cd "$TMPDIR"
  opencode run --help >/dev/null 2>&1 && echo "  PASS: opencode parsed config without crash"
else
  echo "  SKIP: opencode CLI not installed (install at https://opencode.ai)"
fi
echo ""

# 8. Exercise the shell setup path: lib/setup-mandatory-files.sh --platform opencode
echo "--- [8/12] Generate project files via lib/setup-mandatory-files.sh --platform opencode ---"
SHTMP=$(mktemp -d /tmp/metaswarm-opencode-sh-XXXXXX)
trap "rm -rf '$TMPDIR' '$SHTMP'" EXIT
bash "$ROOT/lib/setup-mandatory-files.sh" "$SHTMP" 100 "npm test" --platform opencode >/dev/null 2>&1
fail=0
for ref in opencode.json .opencode/commands/setup.md .opencode/commands/start-task.md .opencode/commands/prime.md .opencode/commands/review-design.md .opencode/commands/design-review-gate.md .opencode/commands/orchestrated-execution.md .opencode/commands/self-reflect.md .opencode/commands/handoff.md .opencode/commands/pr-shepherd.md .opencode/commands/brainstorm.md .opencode/commands/update.md .opencode/commands/status.md .opencode/commands/handle-pr-comments.md .opencode/commands/create-issue.md .opencode/commands/external-tools-health.md .opencode/agents/issue-orchestrator.md .opencode/agents/architect-agent.md .opencode/agents/product-manager-agent.md .opencode/agents/designer-agent.md .opencode/agents/security-design-agent.md .opencode/agents/cto-agent.md .opencode/agents/coder-agent.md .opencode/agents/code-review-agent.md .opencode/agents/researcher-agent.md .opencode/agents/test-automator-agent.md .opencode/agents/security-auditor-agent.md .opencode/agents/knowledge-curator-agent.md .opencode/agents/pr-shepherd-agent.md .opencode/agents/release-engineer-agent.md .opencode/agents/sre-agent.md .opencode/agents/customer-service-agent.md .opencode/agents/metrics-agent.md .opencode/agents/swarm-coordinator-agent.md .opencode/agents/slack-coordinator-agent.md .opencode/plugins/metaswarm-session.js .opencode/OPENCODE.md; do
  if [ -f "$SHTMP/$ref" ]; then
    echo "  PASS: $ref created by shell setup"
  else
    echo "  FAIL: $ref missing from shell setup"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1
# Skills copied by shell setup
sh_skills=$(ls -d "$SHTMP"/.opencode/skills/*/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$sh_skills" -ge "$skill_count" ]; then
  echo "  PASS: $sh_skills skills created by shell setup"
else
  echo "  FAIL: expected >= $skill_count skills from shell setup, found $sh_skills"
  exit 1
fi
# Re-run and confirm existing files are preserved (copy-only-when-missing)
marker="# local edit preserved"
echo "$marker" >> "$SHTMP/.opencode/OPENCODE.md"
bash "$ROOT/lib/setup-mandatory-files.sh" "$SHTMP" 100 "npm test" --platform opencode >/dev/null 2>&1
if grep -q "$marker" "$SHTMP/.opencode/OPENCODE.md"; then
  echo "  PASS: rerun preserved local edits (copy-only-when-missing)"
else
  echo "  FAIL: rerun clobbered local edits"
  exit 1
fi
echo ""

# 9. Exercise the resource validation path: lib/sync-resources.js --check
echo "--- [9/12] Validate lib/sync-resources.js --check passes ---"
if node "$ROOT/lib/sync-resources.js" --check >/dev/null 2>&1; then
  echo "  PASS: sync-resources validation passed"
else
  echo "  FAIL: sync-resources validation failed"
  node "$ROOT/lib/sync-resources.js" --check || true
  exit 1
fi
echo ""

# 10. CLI --help mentions the --opencode flag
echo "--- [10/12] Verify cli/metaswarm.js --help mentions --opencode ---"
help_out=$(node "$ROOT/cli/metaswarm.js" --help 2>&1)
if echo "$help_out" | grep -qF -- "--opencode"; then
  echo "  PASS: --help output mentions --opencode"
else
  echo "  FAIL: --help output does not mention --opencode"
  echo "$help_out"
  exit 1
fi
echo ""

# 10.5 Verify lib/platform-detect.js detects OpenCode directly
echo "--- [10.5/12] Verify lib/platform-detect.js detects OpenCode platform ---"
detect_out=$(node -e "const pd = require('$ROOT/lib/platform-detect.js'); const platforms = pd.detectPlatforms ? pd.detectPlatforms() : null; if (!platforms || !platforms.opencode) { console.error('FAIL'); process.exit(1); } console.log('opencode:', platforms.opencode.installed ? 'installed' : 'not installed'); console.log('PASS');" 2>&1)
if echo "$detect_out" | grep -q "PASS"; then
  echo "  PASS: platform detection module correctly identifies opencode"
else
  echo "  FAIL: platform detection module missing opencode support"
  echo "$detect_out"
  exit 1
fi
echo ""

# 11. CLI init --opencode runs cleanly and points to setup --opencode
echo "--- [11/12] Verify cli/metaswarm.js init --opencode directs to setup --opencode ---"
if init_out=$(node "$ROOT/cli/metaswarm.js" init --opencode 2>&1); then
  if echo "$init_out" | grep -qF -- "setup --opencode"; then
    echo "  PASS: init --opencode succeeded and directs to setup --opencode"
  else
    echo "  FAIL: init --opencode output missing 'setup --opencode' guidance"
    echo "$init_out"
    exit 1
  fi
else
  echo "  FAIL: init --opencode exited non-zero"
  echo "$init_out"
  exit 1
fi
echo ""

# 12. session-start.sh hook with METASWARM_PLATFORM=opencode in a configured project
echo "--- [12/12] Verify hooks/session-start.sh runs for opencode platform ---"
HOOKTMP=$(mktemp -d /tmp/metaswarm-opencode-hook-XXXXXX)
trap "rm -rf '$TMPDIR' '$SHTMP' '$HOOKTMP'" EXIT
mkdir -p "$HOOKTMP/.metaswarm"
echo '{"distribution":"plugin"}' > "$HOOKTMP/.metaswarm/project-profile.json"
if hook_out=$(cd "$HOOKTMP" && METASWARM_PLATFORM=opencode PLUGIN_ROOT="$ROOT" bash "$ROOT/hooks/session-start.sh" 2>/dev/null); then
  if echo "$hook_out" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{JSON.parse(d);process.exit(0)})" 2>/dev/null; then
    echo "  PASS: session-start.sh produced valid JSON for opencode platform"
  else
    echo "  FAIL: session-start.sh output was not valid JSON"
    echo "$hook_out"
    exit 1
  fi
  # The hook ran in a configured project missing opencode.json, so self-heal
  # should have restored the root config.
  if [ -f "$HOOKTMP/opencode.json" ]; then
    echo "  PASS: self-heal restored missing opencode.json"
  else
    echo "  FAIL: self-heal did not restore opencode.json"
    exit 1
  fi
else
  echo "  FAIL: session-start.sh exited non-zero for opencode platform"
  exit 1
fi
echo ""

echo "=== All tests passed ==="
