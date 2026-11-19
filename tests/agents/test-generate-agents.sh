#!/usr/bin/env bash
# tests/agents/test-generate-agents.sh
# Tests for bin/metaswarm-agents.sh (generate / check / clean) and models.yaml parsing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOL="$REPO_ROOT/bin/metaswarm-agents.sh"
FIXTURE="$SCRIPT_DIR/fixtures/models.yaml"
ROLES="design-reviewer plan-reviewer researcher planner coder adversarial-reviewer pr-shepherd-agent knowledge-curator-agent"
VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/.claude-plugin/plugin.json" | head -1)"
PASS=0
FAIL=0
TMP_BASE="$(mktemp -d)"
# bash 3.2 exits with the EXIT trap's status (0) when `set -u` aborts the script,
# so a crash would look like a pass. DONE is set only after the summary runs.
DONE=0
trap 'rm -rf "${TMP_BASE:?}"; [ "$DONE" = 1 ] || { echo "ABORTED before summary" >&2; exit 1; }' EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
check() { if [ "$2" = "0" ]; then pass "$1"; else fail "$1"; fi; }

N=0
new_proj() {
  N=$((N + 1))
  P="$TMP_BASE/p$N"
  mkdir -p "$P/.metaswarm"
  git -C "$P" init -q
  if [ "${1:-fixture}" = "fixture" ]; then cp "$FIXTURE" "$P/.metaswarm/models.yaml"; fi
}

# run <args...> in $P; sets OUT and RC
run() {
  RC=0
  OUT="$(cd "$P" && CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$TOOL" "$@" 2>&1)" || RC=$?
}

agent_file() { echo "$P/.claude/agents/metaswarm-$1.md"; }
plugin_model() { sed -n 's/^model: //p' "$REPO_ROOT/agents/$1.md" | head -1; }
count_agents() { ls "$P/.claude/agents" 2>/dev/null | wc -l | tr -d ' '; }
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }

echo "Running metaswarm-agents.sh tests..."

echo "Test 1: generate writes expected files"
new_proj
run generate
check "generate exits 0" "$RC"
all_present=0
for r in $ROLES; do [ -f "$(agent_file $r)" ] || all_present=1; done
check "one file per roster role" "$all_present"
f="$(agent_file coder)"
grep -q '^name: metaswarm-coder$' "$f" && pass "name is project-scoped" || fail "name is project-scoped"
grep -q '^model: haiku$' "$f" && pass "model comes from models.yaml" || fail "model comes from models.yaml"
desc="$(sed -n 's/^description: //p' "$REPO_ROOT/agents/coder.md" | head -1)"
grep -qF "description: $desc" "$f" && pass "description from plugin" || fail "description from plugin"
f="$(agent_file design-reviewer)"
grep -q '^disallowedTools: Write, Edit, NotebookEdit$' "$f" && pass "disallowedTools from plugin" || fail "disallowedTools from plugin"
body_line="$(sed -n '/^# Design Reviewer/p' "$REPO_ROOT/agents/design-reviewer.md" | head -1)"
[ "$(grep -cF "$body_line" "$f")" = "1" ] && pass "plugin body copied once" || fail "plugin body copied once"
hdr="$(grep '^<!-- generated-by: metaswarm ' "$f")"
case "$hdr" in
  "<!-- generated-by: metaswarm v$VERSION sha256:"*" — edit .metaswarm/models.yaml, not this file -->") pass "header has plugin version" ;;
  *) fail "header has plugin version: $hdr" ;;
esac
# header sits right after the frontmatter; hash covers everything else
second_dash="$(grep -n '^---$' "$f" | sed -n '2p' | cut -d: -f1)"
sed -n "$((second_dash + 1))p" "$f" | grep -q '^<!-- generated-by: metaswarm ' && pass "header is first body line" || fail "header is first body line"
want="$(awk '!d && /^<!-- generated-by: metaswarm /{d=1;next}1' "$f" | sha)"
case "$hdr" in *"sha256:$want "*) pass "header hash covers the rest of the file" ;; *) fail "header hash covers the rest of the file" ;; esac

echo "Test 2: second run is byte-identical"
cp -R "$P/.claude/agents" "$TMP_BASE/snap$N"
run generate
check "second generate exits 0" "$RC"
diff -r "$P/.claude/agents" "$TMP_BASE/snap$N" >/dev/null && pass "output byte-identical" || fail "output byte-identical"

echo "Test 3: defaults and overrides"
[ "$(sed -n 's/^model: //p' "$(agent_file researcher)")" = "$(plugin_model researcher)" ] && pass "missing role gets plugin default" || fail "missing role gets plugin default"
grep -q '^model: opus$' "$(agent_file design-reviewer)" && pass "reviewer set to opus is opus" || fail "reviewer set to opus is opus"
grep -q '^model: claude-opus-4-5$' "$(agent_file plan-reviewer)" && pass "full model id accepted" || fail "full model id accepted"

echo "Test 4: parse errors exit 2 with line number and write nothing"
parse_case() { # desc, expected line, yaml
  new_proj none
  printf '%b' "$3" > "$P/.metaswarm/models.yaml"
  run generate
  [ "$RC" = "2" ] && has "models.yaml:$2:" && [ ! -d "$P/.claude/agents" ] && pass "$1" || fail "$1 (rc=$RC out=$OUT)"
}
parse_case "flow map" 2 'roles:\n  coder: {claude: opus}\n'
parse_case "tab" 2 'roles:\n\tcoder:\n'
parse_case "odd indentation" 2 'roles:\n coder:\n'
parse_case "too-deep indentation" 4 'roles:\n  coder:\n    claude: opus\n      x: y\n'
parse_case "unknown top-level key" 1 'bogus:\n'
parse_case "unknown role" 2 'roles:\n  validator:\n    claude: opus\n'
parse_case "unknown host key" 3 'roles:\n  coder:\n    openai: gpt\n'
parse_case "bad claude value" 3 'roles:\n  coder:\n    claude: gpt-4\n'
parse_case "non-integer after_failures" 3 'escalation:\n  coder:\n    after_failures: two\n'

echo "Test 5: empty or comment-only models.yaml means defaults"
new_proj none
printf '# only a comment\n\n' > "$P/.metaswarm/models.yaml"
run generate
check "empty-ish file exits 0" "$RC"
ok=0
for r in $ROLES; do [ "$(sed -n 's/^model: //p' "$(agent_file $r)")" = "$(plugin_model $r)" ] || ok=1; done
check "all roles use plugin defaults" "$ok"

echo "Test 6: no models.yaml"
new_proj none
run generate
[ "$RC" = "0" ] && has "no models.yaml — using plugin defaults; run /setup to customize" && [ ! -d "$P/.claude" ] && pass "message, no writes, exit 0" || fail "no models.yaml (rc=$RC out=$OUT)"

echo "Test 7: check"
new_proj
run generate
run check
check "clean tree exits 0" "$RC"
f="$(agent_file coder)"
echo "extra" >> "$f"
run check
[ "$RC" = "1" ] && has "hand-edited" && has "metaswarm-coder.md" && pass "hand-edited detected" || fail "hand-edited detected ($OUT)"
run generate
[ "$RC" = "1" ] && has "metaswarm-coder.md" && pass "generate refuses hand-edited file" || fail "generate refuses hand-edited file ($OUT)"
grep -q '^extra$' "$f" && pass "hand edit preserved without --force" || fail "hand edit preserved without --force"
run generate --force
[ "$RC" = "0" ] && ! grep -q '^extra$' "$f" && pass "--force overwrites hand-edited file" || fail "--force overwrites ($OUT)"
# stale: config changed
sed -i.bak 's/claude: haiku/claude: sonnet/' "$P/.metaswarm/models.yaml"; rm -f "$P/.metaswarm/models.yaml.bak"
run check
[ "$RC" = "1" ] && has "stale" && has "metaswarm-coder.md" && pass "config change is stale" || fail "config change is stale ($OUT)"
run generate
run check
check "regenerate clears stale" "$RC"
# stale: version in header differs (hash recomputed so it is not hand-edited)
rest="$(awk '!d && /^<!-- generated-by: metaswarm /{d=1;next}1' "$f")"
newhash="$(printf '%s\n' "$rest" | sha)"
sed -i.bak "s/^<!-- generated-by: metaswarm v[^ ]* sha256:[0-9a-f]*/<!-- generated-by: metaswarm v0.0.1 sha256:$newhash/" "$f"; rm -f "$f.bak"
run check
[ "$RC" = "1" ] && has "stale" && pass "old header version is stale" || fail "old header version is stale ($OUT)"
run generate
# missing
rm "$(agent_file planner)"
run check
[ "$RC" = "1" ] && has "missing" && has "metaswarm-planner.md" && pass "missing detected" || fail "missing detected ($OUT)"
run generate
# orphan
cp "$(agent_file coder)" "$P/.claude/agents/metaswarm-validator.md"
run check
[ "$RC" = "1" ] && has "orphan" && has "metaswarm-validator.md" && pass "orphan detected" || fail "orphan detected ($OUT)"

echo "Test 8: generate deletes only header-bearing orphans"
printf -- '---\nname: metaswarm-ghost\ndescription: mine\n---\nuser file\n' > "$P/.claude/agents/metaswarm-ghost.md"
run generate
[ ! -e "$P/.claude/agents/metaswarm-validator.md" ] && pass "header orphan deleted" || fail "header orphan deleted"
[ -e "$P/.claude/agents/metaswarm-ghost.md" ] && pass "headerless orphan-named file kept" || fail "headerless orphan-named file kept"

echo "Test 9: same-named user file is never overwritten"
new_proj
mkdir -p "$P/.claude/agents"
printf -- '---\nname: metaswarm-coder\ndescription: mine\n---\nuser coder\n' > "$P/.claude/agents/metaswarm-coder.md"
run generate
[ "$RC" = "1" ] && has "metaswarm-coder.md" && pass "exits 1 naming the file" || fail "exits 1 naming the file ($OUT)"
grep -q '^user coder$' "$P/.claude/agents/metaswarm-coder.md" && pass "user file untouched" || fail "user file untouched"
run generate --force
[ "$RC" = "1" ] && grep -q '^user coder$' "$P/.claude/agents/metaswarm-coder.md" && pass "untouched even with --force" || fail "untouched even with --force"

echo "Test 10: clean removes only header files"
new_proj
run generate
printf 'mine\n' > "$P/.claude/agents/my-own.md"
printf -- '---\nname: metaswarm-coder-custom\n---\nmine\n' > "$P/.claude/agents/metaswarm-custom.md"
run clean
check "clean exits 0" "$RC"
left="$(ls "$P/.claude/agents" | tr '\n' ' ')"
[ "$left" = "metaswarm-custom.md my-own.md " ] && pass "only generated files removed" || fail "only generated files removed: $left"

echo "Test 11: resolve_role_model is sourceable"
new_proj
got="$(cd "$P" && CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash -c ". '$TOOL'; resolve_role_model design-reviewer codex; resolve_role_model coder claude; resolve_role_model researcher claude; resolve_role_model researcher codex")"
[ "$got" = "$(printf 'gpt-5.3-codex\nhaiku\n%s\n' "$(plugin_model researcher)")" ] && pass "resolves config, then plugin default, empty for unset codex" || fail "resolve_role_model: $got"

echo "Test 12: check flags a same-named user-authored file (same verdict as generate)"
new_proj
run generate
printf -- '---\nname: metaswarm-coder\ndescription: mine\n---\nuser coder\n' > "$P/.claude/agents/metaswarm-coder.md"
run check
[ "$RC" = "1" ] && has "metaswarm-coder.md" && pass "check exits 1 naming the conflicting user file" || fail "check on user-authored conflict: rc=$RC $OUT"

echo "Test 13: resolve subcommand (process call, safe for adapters)"
new_proj
run resolve coder claude
[ "$RC" = "0" ] && [ "$OUT" = "haiku" ] && pass "resolve coder claude -> haiku" || fail "resolve coder claude: rc=$RC '$OUT'"
run resolve design-reviewer codex
[ "$OUT" = "gpt-5.3-codex" ] && pass "resolve design-reviewer codex" || fail "resolve design-reviewer codex: '$OUT'"
run resolve nosuchrole claude
[ "$RC" != "0" ] && pass "resolve unknown role fails" || fail "resolve unknown role should fail"

echo "Test 14: skills/commands resolve the script path (PLUGIN_ROOT is not set in other skills)"
BAD=""
for f in skills/status/SKILL.md skills/migrate/SKILL.md skills/setup/SKILL.md commands/update.md commands/metaswarm-update-version.md commands/metaswarm-setup.md; do
  grep -n 'metaswarm-agents.sh' "$REPO_ROOT/$f" | grep -v 'Do NOT copy' | grep -v -F 'command -v metaswarm-agents.sh' | grep -q . && BAD="$BAD $f"
done
[ -z "$BAD" ] && pass "every call site resolves metaswarm-agents.sh via PATH with plugin-root fallback" || fail "unresolved \${PLUGIN_ROOT} call sites:$BAD"

echo "Test 15: quoted YAML scalars are decoded (migration from quoted external-tools.yaml values)"
new_proj none
printf 'roles:\n  coder:\n    claude: "haiku"\n    codex: "gpt-5.3-codex"\n    gemini: \x27flash\x27\n' > "$P/.metaswarm/models.yaml"
run generate
check "generate accepts quoted claude model" "$RC"
grep -q '^model: haiku$' "$P/.claude/agents/metaswarm-coder.md" && pass "quoted claude value written unquoted" || fail "quoted claude value: $(grep '^model:' "$P/.claude/agents/metaswarm-coder.md")"
run resolve coder codex
[ "$OUT" = "gpt-5.3-codex" ] && pass "double-quoted codex value decoded" || fail "double-quoted codex: '$OUT'"
run resolve coder gemini
[ "$OUT" = "flash" ] && pass "single-quoted gemini value decoded" || fail "single-quoted gemini: '$OUT'"

echo "Test 16: check without models.yaml but with leftover generated agents reports them"
new_proj
run generate
rm "$P/.metaswarm/models.yaml"
run check
[ "$RC" = "1" ] && has "metaswarm-agents.sh clean" && pass "check flags leftover generated agents (exit 1, suggests clean)" || fail "leftover generated agents not flagged: rc=$RC $OUT"
new_proj none
run check
[ "$RC" = "0" ] && pass "check with no models.yaml and no generated agents exits 0" || fail "clean project check rc=$RC"

echo "Test 17: aligned values (multiple spaces after the colon) are trimmed"
new_proj none
printf 'roles:\n  coder:\n    claude:  haiku\n    codex:   gpt-5.3-codex\n    gemini:  "flash"\n' > "$P/.metaswarm/models.yaml"
run generate
check "generate accepts aligned claude value" "$RC"
grep -q '^model: haiku$' "$P/.claude/agents/metaswarm-coder.md" && pass "aligned claude value trimmed" || fail "aligned claude value"
run resolve coder codex
[ "$OUT" = "gpt-5.3-codex" ] && pass "aligned codex value trimmed" || fail "aligned codex: '$OUT'"
run resolve coder gemini
[ "$OUT" = "flash" ] && pass "aligned + quoted gemini value" || fail "aligned quoted gemini: '$OUT'"

# --- OpenCode target (generate/check/clean --host opencode) ---
OC_FIXTURE="$SCRIPT_DIR/fixtures/models-opencode.yaml"
new_oc_proj() { new_proj none; cp "$OC_FIXTURE" "$P/.metaswarm/models.yaml"; }
oc_file() { echo "$P/.opencode/agents/$1.md"; }
oc_left() { ls "$P/.opencode/agents" 2>/dev/null | tr '\n' ' '; }
# frontmatter of a file (between the first two --- lines)
fm() { awk '/^---$/ { if (++c == 2) exit; next } c == 1 { print }' "$1"; }

echo "Test 18: opencode host key parses and resolves"
new_oc_proj
run resolve coder opencode
[ "$RC" = "0" ] && [ "$OUT" = "anthropic/claude-sonnet-4-5" ] && pass "resolve coder opencode" || fail "resolve coder opencode: rc=$RC '$OUT'"
run resolve researcher opencode
[ "$RC" = "0" ] && [ -z "$OUT" ] && pass "unset opencode role resolves empty" || fail "unset opencode role: rc=$RC '$OUT'"
new_proj none
printf 'escalation:\n  coder:\n    opencode: a/b\n' > "$P/.metaswarm/models.yaml"
run resolve coder opencode
[ "$RC" = "2" ] && has "models.yaml:3:" && pass "opencode under escalation is rejected" || fail "opencode under escalation: rc=$RC $OUT"

echo "Test 19: generate --host opencode writes full renders for configured roles only"
new_oc_proj
run generate --host opencode
check "generate --host opencode exits 0" "$RC"
[ "$(oc_left)" = "adversarial-reviewer.md coder.md " ] && pass "files only for roles with an opencode value" || fail "opencode files: $(oc_left)"
[ ! -d "$P/.claude" ] && pass "opencode generate writes nothing under .claude" || fail "opencode generate wrote .claude"
f="$(oc_file coder)"
[ "$(sed -n 1p "$f")" = "---" ] && pass "file starts with frontmatter" || fail "file starts with frontmatter"
fm "$f" | grep -q '^model: anthropic/claude-sonnet-4-5$' && pass "model from roles.<role>.opencode" || fail "model from roles.<role>.opencode"
fm "$f" | grep -q '^mode: subagent$' && pass "mode: subagent" || fail "mode: subagent"
desc="$(sed -n 's/^description: //p' "$REPO_ROOT/agents/coder.md" | head -1)"
fm "$f" | grep -qxF "description: $desc" && pass "description verbatim from canonical agent" || fail "description verbatim from canonical agent"
fm "$f" | grep -q 'permission\|edit: deny' && fail "writable role has no permission block" || pass "writable role has no permission block"
hdr="$(grep '^<!-- generated-by: metaswarm ' "$f")"
case "$hdr" in
  "<!-- generated-by: metaswarm v$VERSION sha256:"*" — edit .metaswarm/models.yaml, not this file -->") pass "opencode header has plugin version" ;;
  *) fail "opencode header has plugin version: $hdr" ;;
esac
second_dash="$(grep -n '^---$' "$f" | sed -n '2p' | cut -d: -f1)"
sed -n "$((second_dash + 1))p" "$f" | grep -q '^<!-- generated-by: metaswarm ' && pass "opencode header is first body line" || fail "opencode header is first body line"
want="$(awk '!d && /^<!-- generated-by: metaswarm /{d=1;next}1' "$f" | sha)"
case "$hdr" in *"sha256:$want "*) pass "opencode header hash covers the rest of the file" ;; *) fail "opencode header hash covers the rest of the file" ;; esac
awk 'c >= 2 { print } /^---$/ { c++ }' "$REPO_ROOT/agents/coder.md" > "$TMP_BASE/want-body"
sed -n "$((second_dash + 2)),\$p" "$f" > "$TMP_BASE/got-body"
cmp -s "$TMP_BASE/want-body" "$TMP_BASE/got-body" && pass "canonical body copied verbatim" || fail "canonical body copied verbatim"
f="$(oc_file adversarial-reviewer)"
fm "$f" | grep -q '^model: openai/gpt-5.1$' && pass "read-only role model" || fail "read-only role model"
[ "$(fm "$f" | grep -A1 '^permission:$' | sed -n 2p)" = "  edit: deny" ] && pass "read-only role gets permission: edit: deny" || fail "read-only role gets permission: edit: deny"
bad=0
for g in "$P"/.opencode/agents/*.md; do
  fm "$g" | grep -Eq '^name:|disallowedTools|^model: (opus|sonnet|haiku|inherit)$' && bad=1
  grep -q '^disallowedTools' "$g" && bad=1
done
check "no Claude-style frontmatter (name, disallowedTools, model alias)" "$bad"
cp -R "$P/.opencode/agents" "$TMP_BASE/ocsnap$N"
run generate --host opencode
diff -r "$P/.opencode/agents" "$TMP_BASE/ocsnap$N" >/dev/null && pass "second opencode generate is byte-identical" || fail "second opencode generate is byte-identical"

echo "Test 20: generate --host opencode without models.yaml or without opencode keys"
new_proj none
run generate --host opencode
[ "$RC" = "0" ] && has "no models.yaml" && [ ! -d "$P/.opencode" ] && [ ! -d "$P/.claude" ] && pass "no models.yaml: message, no writes, exit 0" || fail "opencode no models.yaml (rc=$RC out=$OUT)"
new_proj
run generate --host opencode
[ "$RC" = "0" ] && [ ! -d "$P/.opencode" ] && [ ! -d "$P/.claude" ] && pass "no opencode keys: nothing written, exit 0" || fail "opencode no keys (rc=$RC out=$OUT)"
run check --host opencode
check "check --host opencode with no opencode keys exits 0" "$RC"

echo "Test 21: default generate/check/clean ignore opencode keys"
new_proj
run generate
ref="$P/.claude/agents"
new_oc_proj
run generate
check "default generate with opencode keys exits 0" "$RC"
diff -r "$ref" "$P/.claude/agents" >/dev/null && pass "default output byte-identical with opencode keys present" || fail "default output byte-identical with opencode keys present"
[ ! -e "$P/.opencode" ] && pass "default generate creates no .opencode" || fail "default generate creates no .opencode"
run check
[ "$RC" = "0" ] && [ ! -e "$P/.opencode" ] && pass "default check ignores opencode target" || fail "default check with opencode keys: rc=$RC $OUT"
run generate --host opencode
run clean
[ "$(count_agents)" = "0" ] && [ "$(oc_left)" = "adversarial-reviewer.md coder.md " ] && pass "default clean leaves .opencode alone" || fail "default clean touched .opencode: $(oc_left)"
run generate --host bogus
[ "$RC" = "64" ] && pass "unknown --host is a usage error" || fail "unknown --host: rc=$RC $OUT"

echo "Test 22: opencode refuses user-authored and hand-edited targets"
new_oc_proj
mkdir -p "$P/.opencode/agents"
printf -- '---\ndescription: mine\nmode: subagent\n---\nuser coder\n' > "$(oc_file coder)"
run generate --host opencode
[ "$RC" = "1" ] && has ".opencode/agents/coder.md" && pass "exits 1 naming the user-authored file" || fail "opencode user-authored: rc=$RC $OUT"
grep -q '^user coder$' "$(oc_file coder)" && [ ! -e "$(oc_file adversarial-reviewer)" ] && pass "user file untouched, nothing else written" || fail "user file untouched, nothing else written"
run generate --host opencode --force
[ "$RC" = "1" ] && grep -q '^user coder$' "$(oc_file coder)" && pass "untouched even with --force" || fail "opencode untouched even with --force"
run check --host opencode
[ "$RC" = "1" ] && has "conflict" && has ".opencode/agents/coder.md" && pass "check reports the conflict" || fail "opencode check conflict: rc=$RC $OUT"
rm "$(oc_file coder)"
run generate --host opencode
echo "extra" >> "$(oc_file coder)"
run check --host opencode
[ "$RC" = "1" ] && has "hand-edited" && has "coder.md" && pass "check reports hand-edited" || fail "opencode hand-edited: rc=$RC $OUT"
run generate --host opencode
[ "$RC" = "1" ] && grep -q '^extra$' "$(oc_file coder)" && pass "generate refuses hand-edited file" || fail "opencode generate refuses hand-edited: rc=$RC $OUT"
run generate --force --host opencode
[ "$RC" = "0" ] && ! grep -q '^extra$' "$(oc_file coder)" && pass "--force overwrites hand-edited file" || fail "opencode --force: rc=$RC $OUT"

echo "Test 23: check --host opencode reports stale, missing and orphan; generate removes orphans"
run check --host opencode
check "clean opencode tree exits 0" "$RC"
sed -i.bak 's#opencode: openai/gpt-5.1#opencode: openai/gpt-5.2#' "$P/.metaswarm/models.yaml"; rm -f "$P/.metaswarm/models.yaml.bak"
run check --host opencode
[ "$RC" = "1" ] && has "stale" && has "adversarial-reviewer.md" && pass "config change is stale" || fail "opencode stale: rc=$RC $OUT"
run generate --host opencode
grep -q '^model: openai/gpt-5.2$' "$(oc_file adversarial-reviewer)" && pass "regenerate applies the new model" || fail "regenerate applies the new model"
rm "$(oc_file coder)"
run check --host opencode
[ "$RC" = "1" ] && has "missing" && has "coder.md" && pass "missing detected" || fail "opencode missing: rc=$RC $OUT"
run generate --host opencode
# orphan: role no longer configured for opencode
grep -v 'opencode: openai/' "$P/.metaswarm/models.yaml" > "$P/.metaswarm/m.tmp"; mv "$P/.metaswarm/m.tmp" "$P/.metaswarm/models.yaml"
printf 'my own agent\n' > "$P/.opencode/agents/my-own.md"
printf -- '---\ndescription: mine\n---\nuser planner\n' > "$(oc_file planner)"
run check --host opencode
[ "$RC" = "1" ] && has "orphan" && has "adversarial-reviewer.md" && ! has "my-own.md" && ! has "planner.md" && pass "orphan detected, user files ignored" || fail "opencode orphan: rc=$RC $OUT"
run generate --host opencode
[ "$RC" = "0" ] && [ "$(oc_left)" = "coder.md my-own.md planner.md " ] && pass "generate removes the orphan, keeps user files" || fail "opencode orphan removal: rc=$RC $(oc_left)"
run check --host opencode
check "check passes after orphan removal" "$RC"

echo "Test 24: clean --host opencode removes only header-bearing files"
run generate
run clean --host opencode
[ "$RC" = "0" ] && [ "$(oc_left)" = "my-own.md planner.md " ] && pass "only generated opencode files removed" || fail "opencode clean: rc=$RC $(oc_left)"
[ "$(count_agents)" = "8" ] && pass "clean --host opencode leaves .claude/agents alone" || fail "clean --host opencode touched .claude: $(count_agents)"
new_oc_proj
run generate --host opencode
rm "$P/.metaswarm/models.yaml"
run check --host opencode
[ "$RC" = "1" ] && has "clean --host opencode" && pass "check flags leftover opencode agents without models.yaml" || fail "opencode leftover: rc=$RC $OUT"

echo "Test 25: opencode target only ever touches <roster-role>.md"
new_oc_proj
run generate --host opencode
# header-bearing file with a non-role name (another tool's, or a renamed copy)
cp "$(oc_file coder)" "$P/.opencode/agents/architect-agent.md"
# user notes that merely quote the header prefix on a body line
printf 'my notes\n<!-- generated-by: metaswarm v0 sha256:abc quoted in my notes -->\n' > "$P/.opencode/agents/my-notes.md"
run check --host opencode
[ "$RC" = "0" ] && ! has "architect-agent.md" && ! has "my-notes.md" && pass "check does not report non-role files" || fail "check reports non-role files: rc=$RC $OUT"
run generate --host opencode
[ "$RC" = "0" ] && [ -e "$P/.opencode/agents/architect-agent.md" ] && pass "generate keeps a header-bearing non-role file" || fail "generate removed architect-agent.md: rc=$RC $OUT"
[ -e "$P/.opencode/agents/my-notes.md" ] && pass "generate keeps a non-role file quoting the header" || fail "generate removed my-notes.md"
run clean --host opencode
[ "$RC" = "0" ] && [ "$(oc_left)" = "architect-agent.md my-notes.md " ] && pass "clean removes only generated roster-role files" || fail "clean and non-role files: rc=$RC $(oc_left)"
rm "$P/.metaswarm/models.yaml"
run check --host opencode
[ "$RC" = "0" ] && pass "no-models.yaml check ignores non-role files" || fail "no-models.yaml check flags non-role files: rc=$RC $OUT"

echo "Test 26: a hand-edited opencode orphan is not deleted without --force"
new_oc_proj
run generate --host opencode
echo "my tweak" >> "$(oc_file adversarial-reviewer)"
grep -v 'opencode: openai/' "$P/.metaswarm/models.yaml" > "$P/.metaswarm/m.tmp"; mv "$P/.metaswarm/m.tmp" "$P/.metaswarm/models.yaml"
sed -i.bak 's#opencode: anthropic/claude-sonnet-4-5#opencode: anthropic/claude-opus-4-5#' "$P/.metaswarm/models.yaml"; rm -f "$P/.metaswarm/models.yaml.bak"
run generate --host opencode
[ "$RC" = "1" ] && has "hand-edited" && has "adversarial-reviewer.md" && pass "hand-edited orphan refused, exit 1" || fail "hand-edited orphan: rc=$RC $OUT"
grep -q '^my tweak$' "$(oc_file adversarial-reviewer)" && pass "hand-edited orphan kept" || fail "hand-edited orphan kept"
grep -q '^model: anthropic/claude-sonnet-4-5$' "$(oc_file coder)" && pass "nothing written when an orphan is refused" || fail "nothing written when an orphan is refused"
run generate --host opencode --force
[ "$RC" = "0" ] && [ "$(oc_left)" = "coder.md " ] && pass "--force removes the hand-edited orphan" || fail "--force orphan: rc=$RC $(oc_left)"
grep -q '^model: anthropic/claude-opus-4-5$' "$(oc_file coder)" && pass "--force run writes the configured roles" || fail "--force run writes the configured roles"

echo "Test 27: opencode value must be provider/model-id"
oc_parse_case() { # desc, yaml value
  new_proj none
  printf 'roles:\n  coder:\n    opencode: %s\n' "$2" > "$P/.metaswarm/models.yaml"
  run generate --host opencode
  [ "$RC" = "2" ] && has "models.yaml:3:" && has "opencode" && [ ! -d "$P/.opencode" ] && pass "$1" || fail "$1 (rc=$RC out=$OUT)"
}
oc_parse_case "bare alias rejected" 'sonnet'
oc_parse_case "quoted value with colon-space rejected" '"x: y"'
oc_parse_case "value with a space rejected" 'openai/gpt 5'
new_proj none
printf 'roles:\n  coder:\n    opencode: "openrouter/anthropic/claude-3.7:beta"\n' > "$P/.metaswarm/models.yaml"
run resolve coder opencode
[ "$RC" = "0" ] && [ "$OUT" = "openrouter/anthropic/claude-3.7:beta" ] && pass "nested provider path with colon accepted" || fail "nested provider path: rc=$RC $OUT"

echo "Test 28: --host argument surface"
new_oc_proj
run generate --hostile
[ "$RC" = "0" ] && [ "$(count_agents)" = "8" ] && [ ! -e "$P/.opencode" ] && pass "generate --hostile is an ignored extra arg (default generate runs)" || fail "generate --hostile: rc=$RC $OUT"
run generate foo
[ "$RC" = "0" ] && [ ! -e "$P/.opencode" ] && pass "generate foo still runs the default generate" || fail "generate foo: rc=$RC $OUT"
usage_case() { local d="$1"; shift; run "$@"; [ "$RC" = "64" ] && [ ! -e "$P/.opencode" ] && pass "$d" || fail "$d: rc=$RC $OUT"; }
usage_case "--host=opencode form is a usage error" generate --host=opencode --host
usage_case "--host claude is a usage error" generate --host claude
usage_case "--host without a value is a usage error" generate --host
usage_case "extra argument with --host is a usage error" generate --host opencode extra
usage_case "check --host opencode --force is a usage error" check --host opencode --force
usage_case "clean --host opencode --force is a usage error" clean --force --host opencode

echo ""
echo "Results: $PASS passed, $FAIL failed"
DONE=1
[ "$FAIL" -eq 0 ] || exit 1
