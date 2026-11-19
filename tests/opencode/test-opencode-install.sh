#!/usr/bin/env bash
# tests/opencode/test-opencode-install.sh
# Tests for .opencode/install.sh: the per-machine OpenCode installer (clone or --from,
# symlinks for skills/commands/plugin, generated agents, opencode.json, the scoped
# opencode() shell function) and its --migrate-project mode.
#
# No network: clones come from a file:// bare repo built here. Nothing is written
# outside the temp directory; HOME and XDG_CONFIG_HOME are temp directories.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL="$ROOT/.opencode/install.sh"
OLD_LAYOUT="$SCRIPT_DIR/fixtures/old-layout"
PASS=0
FAIL=0
TMP_BASE="$(mktemp -d)"
# bash 3.2 exits with the EXIT trap's status (0) when `set -u` aborts the script,
# so a crash would look like a pass. DONE is set only after the summary runs.
DONE=0
trap 'chmod -R u+rwx "${TMP_BASE:?}" 2>/dev/null; rm -rf "${TMP_BASE:?}"; [ "$DONE" = 1 ] || { echo "ABORTED before summary" >&2; exit 1; }' EXIT

unset OPENCODE_CONFIG_DIR PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
unset METASWARM_REPO_URL METASWARM_REF CDPATH extensionPath MS_PLUGIN

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
check() { if [ "$2" = "0" ]; then pass "$1"; else fail "$1"; fi; }
ok() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

CWD="$TMP_BASE/cwd"
mkdir -p "$CWD"
N=0
EXCLUDED="metaswarm-setup.md metaswarm-update-version.md update.md start.md"
URL_UNUSED="file://$TMP_BASE/no-such-repo.git"   # a network URL must never be reached

# new_env: fresh HOME (H), XDG_CONFIG_HOME (X) and the OpenCode dir under it (OC)
new_env() {
  N=$((N + 1))
  H="$TMP_BASE/e$N/home"
  X="$TMP_BASE/e$N/xdg"
  OC="$X/opencode"
  mkdir -p "$H" "$X"
}

# inst <args...>: run the installer with the temp HOME/XDG; sets OUT and RC
inst() {
  RC=0
  OUT="$(cd "$CWD" && HOME="$H" XDG_CONFIG_HOME="$X" METASWARM_REPO_URL="${REPO_URL:-$URL_UNUSED}" METASWARM_REF="${REF:-distro}" bash "$INSTALL" "$@" 2>&1 </dev/null)" || RC=$?
}

has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }
names() { ls "$1" 2>/dev/null | sort; }
# snap <dir>: names, link targets and file hashes of everything under <dir>,
# leaving out a clone at <dir>/metaswarm
snap() {
  [ -d "$1" ] || { echo "no such dir"; return 0; }
  (
    cd "$1"
    find . -path ./metaswarm -prune -o -print | sort
    find . -path ./metaswarm -prune -o -type l -print | sort | while IFS= read -r l; do printf '%s -> %s\n' "$l" "$(readlink "$l")"; done
    find . -path ./metaswarm -prune -o -type f -print | sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(sha < "$f")"; done
  )
}
# links_into <dir> <root>: every entry of <dir> is a symlink whose text starts with <root>/
links_into() {
  local l t n=0
  for l in "$1"/*; do
    [ -L "$l" ] || return 1
    t="$(readlink "$l")"
    case "$t" in "$2"/*) ;; *) return 1 ;; esac
    [ -e "$l" ] || return 1
    n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}
json_get() { node -e 'const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = process.argv[2].split(".").reduce((o, k) => (o == null ? undefined : o[k]), c); process.stdout.write(v === undefined ? "<undefined>" : typeof v === "string" ? v : JSON.stringify(v));' "$1" "$2"; }

# mk_tree <dir>: a small metaswarm checkout (4 agents, 2 skills, 3 linked commands,
# the 4 excluded commands, a commands/metaswarm/ TOML dir, a non-skill directory)
mk_tree() {
  local t="$1" f
  mkdir -p "$t/.opencode" "$t/.claude-plugin" "$t/agents" "$t/skills" "$t/commands/metaswarm"
  cp -R "$ROOT/bin" "$t/bin"
  cp -R "$ROOT/.opencode/lib" "$t/.opencode/lib"
  cp "$ROOT/.claude-plugin/plugin.json" "$t/.claude-plugin/plugin.json"
  if [ -f "$ROOT/.opencode/OPENCODE.md" ]; then cp "$ROOT/.opencode/OPENCODE.md" "$t/.opencode/OPENCODE.md"; fi
  for f in $(cd "$ROOT/agents" && ls *.md | sort | sed -n '1,4p'); do cp "$ROOT/agents/$f" "$t/agents/$f"; done
  cp -R "$ROOT/skills/start" "$t/skills/start"
  cp -R "$ROOT/skills/status" "$t/skills/status"
  mkdir -p "$t/skills/not-a-skill"; echo "no SKILL.md here" > "$t/skills/not-a-skill/notes.txt"
  for f in prime.md status.md start-task.md $EXCLUDED; do cp "$ROOT/commands/$f" "$t/commands/$f"; done
  echo 'description = "x"' > "$t/commands/metaswarm/prime.toml"
  rm -f "$t/.opencode/plugins/metaswarm-session.js" "$t/.opencode/mcp/beads-mcp-server.ts"
}
# add_wu4_stubs <tree>: the two files that arrive with the plugin/MCP work unit
add_wu4_stubs() {
  mkdir -p "$1/.opencode/plugins" "$1/.opencode/mcp"
  echo 'export default { id: "metaswarm-session" };' > "$1/.opencode/plugins/metaswarm-session.js"
  echo '// stub beads MCP server' > "$1/.opencode/mcp/beads-mcp-server.ts"
}
write_user_agent() { printf -- '---\ndescription: mine\nmode: primary\n---\n\n# My own agent\n' > "$1"; }

T="$TMP_BASE/tree"          # fixture checkout without plugin and MCP server
mk_tree "$T"
TW="$TMP_BASE/tree wu4"     # same, with both files, and a space in its path
mk_tree "$TW"
add_wu4_stubs "$TW"
A1="$(names "$T/agents" | sed -n '1p')"
A2="$(names "$T/agents" | sed -n '2p')"
FN_LINE="opencode() { PLUGIN_ROOT='$T' PATH='$T/bin':\"\$PATH\" command opencode \"\$@\"; }"

echo "Running .opencode/install.sh tests..."

echo "Test 1: static checks"
[ -f "$INSTALL" ] && pass "install.sh exists" || fail "install.sh exists"
[ -x "$INSTALL" ] && pass "install.sh is executable" || fail "install.sh is executable"
bash -n "$INSTALL" 2>/dev/null && pass "bash -n" || fail "bash -n"
for pat in 'readlink -f' 'realpath' 'sed -i' 'declare -A' 'mapfile' '--force' '${[A-Za-z_]*,,}' '&>>' 'rm -rf' 'rm -fr' 'rm -r '; do
  if [ -f "$INSTALL" ] && ! grep -q -e "$pat" "$INSTALL"; then pass "no '$pat'"; else fail "no '$pat'"; fi
done
[ "$(grep -v '^[[:space:]]*$' "$INSTALL" 2>/dev/null | tail -1)" = 'main "$@"' ] && pass "last line is main \"\$@\"" || fail "last line is main \"\$@\""
grep -q '^DEFAULT_REPO_URL="https://github.com/ethiclab/metaswarm.git"$' "$INSTALL" 2>/dev/null && pass "DEFAULT_REPO_URL is a top-level variable" || fail "DEFAULT_REPO_URL is a top-level variable"
grep -q '^DEFAULT_REF="opencode"$' "$INSTALL" 2>/dev/null && pass "DEFAULT_REF is a top-level variable" || fail "DEFAULT_REF is a top-level variable"
grep -Eq '^[[:space:]]*(echo|printf).*export PLUGIN_ROOT' "$INSTALL" 2>/dev/null && fail "never prints an export of PLUGIN_ROOT" || pass "never prints an export of PLUGIN_ROOT"

echo "Test 2: --from a local checkout"
new_env
printf 'export A=1\n' > "$H/.bashrc"; printf 'export B=2\n' > "$H/.zshrc"; printf 'export C=3\n' > "$H/.profile"
home_before="$(snap "$H")"
inst --from "$T"
check "exits 0 (last line: $(printf '%s' "$OUT" | tail -1))" "$RC"
ok "skills are symlinks that resolve into the checkout" links_into "$OC/skills" "$T/skills"
[ "$(names "$OC/skills" | tr '\n' ' ')" = "start status " ] && pass "one link per directory with a SKILL.md" || fail "skill links: $(names "$OC/skills" | tr '\n' ' ')"
[ "$(readlink "$OC/skills/start" 2>/dev/null)" = "$T/skills/start" ] && [ -f "$OC/skills/start/SKILL.md" ] && pass "skill link target is absolute and readable" || fail "skill link target: $(readlink "$OC/skills/start" 2>/dev/null)"
ok "commands are symlinks that resolve into the checkout" links_into "$OC/commands" "$T/commands"
[ "$(names "$OC/commands" | tr '\n' ' ')" = "prime.md start-task.md status.md " ] && pass "excluded commands and the TOML directory are not linked" || fail "command links: $(names "$OC/commands" | tr '\n' ' ')"
[ "$(names "$OC/agents")" = "$(names "$T/agents")" ] && [ -n "$(names "$OC/agents")" ] && pass "agents generated for every agents/*.md" || fail "agents: $(names "$OC/agents" | tr '\n' ' ')"
grep -q '^mode: subagent$' "$OC/agents/$A1" 2>/dev/null && [ ! -L "$OC/agents/$A1" ] && pass "agents are generated files, not links" || fail "agents are generated files, not links"
[ ! -e "$OC/plugins/metaswarm-session.js" ] && [ ! -L "$OC/plugins/metaswarm-session.js" ] && pass "no plugin link when the checkout has no plugin" || fail "no plugin link when the checkout has no plugin"
has "$FN_LINE" && pass "prints the scoped opencode() function with the checkout path" || fail "scoped function missing: $(printf '%s' "$OUT" | grep 'opencode()' | head -2)"
printf '%s\n' "$OUT" | grep -Eq '^[[:space:]]*export PLUGIN_ROOT' && fail "no bare export PLUGIN_ROOT line" || pass "no bare export PLUGIN_ROOT line"
printf '%s\n' "$OUT" | grep -q 'export PLUGIN_ROOT' && fail "export PLUGIN_ROOT is not mentioned at all" || pass "export PLUGIN_ROOT is not mentioned at all"
[ "$(snap "$H")" = "$home_before" ] && pass "no profile file under HOME created or changed" || fail "HOME changed: $(snap "$H" | head -5 | tr '\n' ' ')"
[ ! -e "$OC/metaswarm" ] && pass "--from does not create a clone" || fail "--from does not create a clone"
[ ! -e "$T/.git" ] && pass "--from does not run git init/clone in the checkout" || fail "--from created .git in the checkout"
has "$T" && printf '%s\n' "$OUT" | grep -qi 'from' && pass "reports the local checkout in use" || fail "reports the local checkout in use"
[ -z "$(ls -A "$CWD")" ] && pass "nothing created in the cwd" || fail "cwd: $(ls -A "$CWD" | tr '\n' ' ')"
first="$(snap "$OC")"
inst --from "$T"
[ "$RC" = "0" ] && [ "$(snap "$OC")" = "$first" ] && pass "second run is idempotent (same tree, link targets and bytes)" || fail "second run differs: rc=$RC $(diff <(printf '%s\n' "$first") <(snap "$OC") | head -5 | tr '\n' ' ')"
printf '%s\n' "$OUT" | grep -qi 'warning' && fail "second run prints no warning" || pass "second run prints no warning"
# relative --from
RCREL=0
OUTREL="$(cd "$TMP_BASE" && HOME="$H" XDG_CONFIG_HOME="$X" bash "$INSTALL" --from tree 2>&1 </dev/null)" || RCREL=$?
[ "$RCREL" = "0" ] && [ "$(snap "$OC")" = "$first" ] && pass "relative --from gives the same absolute links" || fail "relative --from: rc=$RCREL"

echo "Test 3: --from validation"
new_env
mkdir -p "$TMP_BASE/empty-tree"
inst --from "$TMP_BASE/empty-tree"
[ "$RC" != "0" ] && [ "$RC" != "64" ] && [ ! -e "$OC" ] && pass "a directory that is not a metaswarm checkout: error, nothing created" || fail "bad --from: rc=$RC $(ls -A "$X" | tr '\n' ' ')"
inst --from "$TMP_BASE/does-not-exist"
[ "$RC" != "0" ] && [ ! -e "$OC" ] && pass "a missing --from path: error, nothing created" || fail "missing --from: rc=$RC"
cp -R "$T" "$TMP_BASE/tree-nogen"; mv "$TMP_BASE/tree-nogen/.opencode/lib/generate-agents.sh" "$TMP_BASE/tree-nogen/.opencode/lib/moved-away"
inst --from "$TMP_BASE/tree-nogen"
[ "$RC" != "0" ] && [ ! -e "$OC/skills" ] && pass "a checkout without the agent generator: error before any link" || fail "no generator: rc=$RC"

echo "Test 4: targets that are not ours are kept"
new_env
mkdir -p "$OC/skills/start" "$OC/commands" "$OC/agents" "$TMP_BASE/e$N/elsewhere/status" "$TMP_BASE/e$N/elsewhere/mine"
echo "my own skill" > "$OC/skills/start/SKILL.md"                       # real dir
echo "my own command" > "$OC/commands/prime.md"                        # real file
ln -s "$TMP_BASE/e$N/elsewhere/status" "$OC/skills/status"             # foreign symlink at a target
ln -s "$TMP_BASE/e$N/elsewhere/mine" "$OC/skills/mine"                 # unrelated user symlink
ln -s "$TMP_BASE/e$N/elsewhere/nowhere.md" "$OC/commands/dangling.md"  # unrelated dangling user symlink
write_user_agent "$OC/agents/$A1"; ua="$(sha < "$OC/agents/$A1")"
inst --from "$T"
check "exits 0 with collisions" "$RC"
[ ! -L "$OC/skills/start" ] && [ "$(cat "$OC/skills/start/SKILL.md")" = "my own skill" ] && [ "$(ls "$OC/skills/start")" = "SKILL.md" ] && pass "real directory kept byte-identical" || fail "real directory kept"
[ ! -L "$OC/commands/prime.md" ] && [ "$(cat "$OC/commands/prime.md")" = "my own command" ] && pass "real file kept byte-identical" || fail "real file kept"
[ "$(readlink "$OC/skills/status")" = "$TMP_BASE/e$N/elsewhere/status" ] && pass "foreign symlink at a target kept" || fail "foreign symlink at a target kept"
has "link(s) were skipped" && pass "skipped links are summarised at the end" || fail "no summary of skipped links"
for p in "$OC/skills/start" "$OC/commands/prime.md" "$OC/skills/status"; do
  printf '%s\n' "$OUT" | grep -F -- "$p" | grep -qi 'warning' && pass "warning names ${p#"$OC"/}" || fail "warning names ${p#"$OC"/}: $(printf '%s\n' "$OUT" | grep -i warning | head -3)"
done
[ "$(readlink "$OC/skills/mine")" = "$TMP_BASE/e$N/elsewhere/mine" ] && [ "$(readlink "$OC/commands/dangling.md")" = "$TMP_BASE/e$N/elsewhere/nowhere.md" ] && pass "unrelated user symlinks survive" || fail "unrelated user symlinks survive"
[ -L "$OC/commands/status.md" ] && [ -L "$OC/commands/start-task.md" ] && pass "the other links are still made" || fail "the other links are still made"
[ "$(sha < "$OC/agents/$A1")" = "$ua" ] && [ -f "$OC/agents/$A2" ] && pass "user-authored agent kept, others generated" || fail "user-authored agent kept, others generated"
printf '%s\n' "$OUT" | grep -F -- "$OC/agents/$A1" | grep -qi 'skip' && pass "generator warning names the user-authored agent" || fail "generator warning for the user agent: $(printf '%s\n' "$OUT" | grep -F -- "$A1" | head -2)"
inst --from "$T"
[ "$RC" = "0" ] && [ "$(readlink "$OC/skills/mine")" = "$TMP_BASE/e$N/elsewhere/mine" ] && [ -L "$OC/commands/dangling.md" ] && [ "$(readlink "$OC/skills/status")" = "$TMP_BASE/e$N/elsewhere/status" ] && [ "$(sha < "$OC/agents/$A1")" = "$ua" ] && pass "all of them survive a re-run" || fail "survive a re-run: rc=$RC"

echo "Test 5: stale links into the checkout are removed"
new_env
TS="$TMP_BASE/e$N/tree"; cp -R "$T" "$TS"
inst --from "$TS"
check "setup install exits 0" "$RC"
mkdir -p "$OC/plugins"
ln -s "$TS/skills/never-existed" "$OC/skills/never-existed"           # dangling, ours by prefix
ln -s "$TS/.opencode/plugins/old-plugin.js" "$OC/plugins/old-plugin.js"
mv "$TS/skills/status" "$TMP_BASE/e$N/status-moved-away"              # source removed: link now dangles
mv "$TS/commands/prime.md" "$TMP_BASE/e$N/prime-moved-away.md"
inst --from "$TS"
check "re-run exits 0" "$RC"
[ ! -L "$OC/skills/status" ] && [ ! -e "$OC/skills/status" ] && [ ! -L "$OC/commands/prime.md" ] && pass "links whose source was removed are gone" || fail "stale links remain: $(names "$OC/skills" | tr '\n' ' ') $(names "$OC/commands" | tr '\n' ' ')"
[ ! -L "$OC/skills/never-existed" ] && [ ! -L "$OC/plugins/old-plugin.js" ] && pass "dangling links into the checkout are gone" || fail "dangling links into the checkout remain"
[ -L "$OC/skills/start" ] && [ -L "$OC/commands/status.md" ] && pass "live links remain" || fail "live links remain"
# the checkout reached through a symlinked path: links made via the physical path are still ours
new_env
ln -s "$T" "$TMP_BASE/e$N/tree-link"
inst --from "$T"
inst --from "$TMP_BASE/e$N/tree-link"
[ "$RC" = "0" ] && ! printf '%s\n' "$OUT" | grep -qi 'warning' && pass "checkout behind a symlink: physical-path links are recognised as ours" || fail "checkout behind a symlink: rc=$RC $(printf '%s\n' "$OUT" | grep -i warning | head -2)"
ok "checkout behind a symlink: links resolve" links_into "$OC/skills" "$TMP_BASE/e$N/tree-link/skills"

echo "Test 6: opencode.json"
new_env
inst --from "$T"
CFG="$OC/opencode.json"
[ -f "$CFG" ] && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$CFG" 2>/dev/null && pass "written when absent, valid JSON" || fail "written when absent, valid JSON"
[ "$(json_get "$CFG" '$schema')" = "https://opencode.ai/config.json" ] && pass "\$schema set" || fail "\$schema: $(json_get "$CFG" '$schema')"
i0="$(json_get "$CFG" instructions.0)"
[ "$i0" = "$T/.opencode/OPENCODE.md" ] && [ -f "$i0" ] && pass "instructions[0] is the checkout's OPENCODE.md and exists" || fail "instructions[0]: $i0"
grep -q '{file:' "$CFG" && fail "no {file: reference" || pass "no {file: reference"
[ "$(json_get "$CFG" mcp)" = "<undefined>" ] && pass "no mcp key when the checkout has no MCP server" || fail "mcp key present: $(json_get "$CFG" mcp)"
[ ! -e "$OC/opencode.jsonc" ] && pass "no opencode.jsonc created" || fail "no opencode.jsonc created"
before="$(sha < "$CFG")"
inst --from "$T"
[ "$(sha < "$CFG")" = "$before" ] && pass "config that references the checkout: unchanged on re-run" || fail "config changed on re-run"
! has '"instructions"' && ! has '"mcp"' && pass "config that references the checkout: no snippet printed" || fail "snippet printed for a config that references the checkout"
# foreign opencode.json
new_env; mkdir -p "$OC"
printf '{\n  "theme": "mine"\n}\n' > "$OC/opencode.json"; before="$(sha < "$OC/opencode.json")"
inst --from "$T"
[ "$RC" = "0" ] && [ "$(sha < "$OC/opencode.json")" = "$before" ] && [ "$(ls "$OC" | grep -c '^opencode\.json')" = "1" ] && pass "foreign opencode.json untouched" || fail "foreign opencode.json: rc=$RC"
has '"instructions"' && has "\"$T/.opencode/OPENCODE.md\"" && pass "foreign opencode.json: instructions snippet printed" || fail "foreign opencode.json: instructions snippet missing"
has '"mcp"' && fail "foreign opencode.json: no mcp snippet without a server" || pass "foreign opencode.json: no mcp snippet without a server"
# foreign opencode.jsonc
new_env; mkdir -p "$OC"
printf '{\n  // my settings\n  "theme": "mine",\n}\n' > "$OC/opencode.jsonc"; before="$(sha < "$OC/opencode.jsonc")"
inst --from "$T"
[ "$RC" = "0" ] && [ "$(sha < "$OC/opencode.jsonc")" = "$before" ] && [ ! -e "$OC/opencode.json" ] && pass "foreign opencode.jsonc untouched, no opencode.json written" || fail "foreign opencode.jsonc: rc=$RC"
has '"instructions"' && has "\"$T/.opencode/OPENCODE.md\"" && pass "foreign opencode.jsonc: instructions snippet printed" || fail "foreign opencode.jsonc: snippet missing"
# jsonc that already references the checkout
printf '{\n  // metaswarm\n  "instructions": ["%s/.opencode/OPENCODE.md"],\n}\n' "$T" > "$OC/opencode.jsonc"
inst --from "$T"
[ "$RC" = "0" ] && ! has '"instructions"' && pass "opencode.jsonc that references the checkout: no snippet" || fail "jsonc referencing the checkout: snippet printed"

echo "Test 7: plugin and MCP server present in the checkout"
new_env
inst --from "$TW"
check "exits 0 with a space in the checkout path" "$RC"
[ "$(readlink "$OC/plugins/metaswarm-session.js" 2>/dev/null)" = "$TW/.opencode/plugins/metaswarm-session.js" ] && [ -f "$OC/plugins/metaswarm-session.js" ] && pass "plugin linked" || fail "plugin linked: $(readlink "$OC/plugins/metaswarm-session.js" 2>/dev/null)"
[ "$(names "$OC/plugins")" = "metaswarm-session.js" ] && pass "only the plugin is linked under plugins/" || fail "plugins/: $(names "$OC/plugins" | tr '\n' ' ')"
CFG="$OC/opencode.json"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$CFG" 2>/dev/null && pass "config is valid JSON with a space in the path" || fail "config is valid JSON with a space in the path"
[ "$(json_get "$CFG" instructions.0)" = "$TW/.opencode/OPENCODE.md" ] && pass "instructions path keeps the space" || fail "instructions: $(json_get "$CFG" instructions.0)"
[ "$(json_get "$CFG" mcp.servers.beads.type)" = "local" ] && pass "mcp.servers.beads.type is local" || fail "mcp.servers.beads.type: $(json_get "$CFG" mcp.servers.beads.type)"
[ "$(json_get "$CFG" mcp.servers.beads.command)" = "[\"node\",\"$TW/.opencode/mcp/beads-mcp-server.ts\"]" ] && [ -f "$(json_get "$CFG" mcp.servers.beads.command.1)" ] && pass "mcp.servers.beads.command is node + the absolute server path" || fail "command: $(json_get "$CFG" mcp.servers.beads.command)"
[ "$(json_get "$CFG" mcp.servers.beads.enabled)" = "true" ] && pass "mcp.servers.beads.enabled is true" || fail "enabled: $(json_get "$CFG" mcp.servers.beads.enabled)"
[ "$(json_get "$CFG" mcp.beads)" = "<undefined>" ] && [ "$(json_get "$CFG" mcp)" = "{\"servers\":$(json_get "$CFG" mcp.servers)}" ] && pass "only the mcp.servers nesting is used" || fail "mcp shape: $(json_get "$CFG" mcp)"
grep -q '{file:' "$CFG" && fail "no {file: reference" || pass "no {file: reference"
has "opencode() { PLUGIN_ROOT='$TW' PATH='$TW/bin':\"\$PATH\" command opencode \"\$@\"; }" && pass "scoped function quotes a path with a space" || fail "scoped function with a space: $(printf '%s\n' "$OUT" | grep 'opencode()')"
inst --from "$TW"
! has '"instructions"' && ! has '"beads"' && pass "re-run: both entries referenced, no snippet" || fail "re-run printed a snippet"
# instructions present, beads entry missing
printf '{\n  "instructions": ["%s/.opencode/OPENCODE.md"]\n}\n' "$TW" > "$CFG"; before="$(sha < "$CFG")"
inst --from "$TW"
[ "$(sha < "$CFG")" = "$before" ] && has '"beads"' && has '"servers"' && has "$TW/.opencode/mcp/beads-mcp-server.ts" && pass "only the beads entry missing: beads snippet printed, config untouched" || fail "beads snippet missing"
has '"instructions"' && fail "only the beads entry missing: no instructions snippet" || pass "only the beads entry missing: no instructions snippet"
# foreign config, both missing
printf '{ "theme": "mine" }\n' > "$CFG"
inst --from "$TW"
has '"instructions"' && has '"beads"' && pass "foreign config with a server in the checkout: both snippets" || fail "both snippets expected"
# a quote and a backslash in the checkout path still give valid JSON
TQ="$TMP_BASE/tree q\"uo\\te"
mk_tree "$TQ"
new_env
inst --from "$TQ"
[ "$RC" = "0" ] && [ "$(json_get "$OC/opencode.json" instructions.0)" = "$TQ/.opencode/OPENCODE.md" ] && pass "a double quote and a backslash in the path are JSON-escaped" || fail "quote in path: rc=$RC $(json_get "$OC/opencode.json" instructions.0 2>&1 | head -1)"
# a single quote in the path: the printed function must be valid shell that sets the right value
TA="$TMP_BASE/tree it's"
mk_tree "$TA"
new_env
inst --from "$TA"
fn="$(printf '%s\n' "$OUT" | grep 'opencode() {' | head -1)"
got="$(bash -c "$fn"'
command() { shift; printf "%s|%s" "$PLUGIN_ROOT" "${PATH%%:*}"; }
opencode' 2>&1)" || true
[ "$got" = "$TA|$TA/bin" ] && pass "printed function is valid shell for a path with a single quote" || fail "single quote in path: '$got'"

echo "Test 8: where the OpenCode directory is"
new_env
OCD="$TMP_BASE/e$N/explicit"
RC=0; OUT="$(cd "$CWD" && HOME="$H" XDG_CONFIG_HOME="$X" OPENCODE_CONFIG_DIR="$OCD" bash "$INSTALL" --from "$T" 2>&1 </dev/null)" || RC=$?
[ "$RC" = "0" ] && [ -L "$OCD/skills/start" ] && [ -f "$OCD/opencode.json" ] && [ ! -e "$OC" ] && pass "OPENCODE_CONFIG_DIR wins over XDG_CONFIG_HOME" || fail "OPENCODE_CONFIG_DIR: rc=$RC"
new_env
RC=0; OUT="$(cd "$CWD" && env -u XDG_CONFIG_HOME HOME="$H" bash "$INSTALL" --from "$T" 2>&1 </dev/null)" || RC=$?
[ "$RC" = "0" ] && [ -L "$H/.config/opencode/skills/start" ] && [ -f "$H/.config/opencode/agents/$A1" ] && [ -z "$(ls -A "$X")" ] && pass "falls back to \$HOME/.config/opencode" || fail "HOME fallback: rc=$RC"

echo "Test 9: the real tree"
new_env
inst --from "$ROOT"
check "exits 0 against the repository itself" "$RC"
want_skills="$(cd "$ROOT/skills" && for d in */; do [ -f "${d}SKILL.md" ] && echo "${d%/}"; done | sort)"
want_cmds="$(cd "$ROOT/commands" && for f in *.md; do case " $EXCLUDED " in *" $f "*) ;; *) echo "$f" ;; esac; done | sort)"
[ -n "$want_skills" ] && [ "$(names "$OC/skills")" = "$want_skills" ] && pass "every skills/*/SKILL.md directory is linked, nothing else" || fail "real skills: $(names "$OC/skills" | tr '\n' ' ')"
[ -n "$want_cmds" ] && [ "$(names "$OC/commands")" = "$want_cmds" ] && pass "every non-excluded command is linked, nothing else" || fail "real commands: $(names "$OC/commands" | tr '\n' ' ')"
[ "$(names "$OC/agents")" = "$(cd "$ROOT/agents" && ls *.md | sort)" ] && pass "every agents/*.md is generated" || fail "real agents: $(names "$OC/agents" | wc -l)"
ok "real skill links resolve into the repository" links_into "$OC/skills" "$ROOT/skills"
ok "real command links resolve into the repository" links_into "$OC/commands" "$ROOT/commands"
for f in $EXCLUDED; do [ -f "$ROOT/commands/$f" ] || fail "excluded command $f no longer exists in commands/ (update the installer's list)"; done
[ -f "$(json_get "$OC/opencode.json" instructions.0)" ] && pass "instructions[0] exists in the repository" || fail "instructions[0] missing: $(json_get "$OC/opencode.json" instructions.0)"
if [ -f "$ROOT/.opencode/plugins/metaswarm-session.js" ]; then
  [ -L "$OC/plugins/metaswarm-session.js" ] && pass "plugin present in the repository: linked" || fail "plugin present in the repository: linked"
else
  [ ! -e "$OC/plugins/metaswarm-session.js" ] && pass "plugin absent from the repository: not linked" || fail "plugin absent from the repository: not linked"
fi
if [ -f "$ROOT/.opencode/mcp/beads-mcp-server.ts" ]; then
  [ "$(json_get "$OC/opencode.json" mcp.servers.beads.type)" = "local" ] && pass "MCP server present in the repository: configured" || fail "MCP server present in the repository: configured"
else
  [ "$(json_get "$OC/opencode.json" mcp)" = "<undefined>" ] && pass "MCP server absent from the repository: no mcp key" || fail "MCP server absent from the repository: no mcp key"
fi

echo "Test 10: clone and update from a repository URL"
G="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c init.defaultBranch=main"
WORK="$TMP_BASE/work"; BARE="$TMP_BASE/bare.git"
cp -R "$TW" "$WORK"
(cd "$WORK" && $G init -q && $G checkout -q -b distro && $G add -A && $G commit -q -m one) >/dev/null 2>&1 || fail "could not build the source repository"
$G clone -q --bare "$WORK" "$BARE" >/dev/null 2>&1 || fail "could not build the bare repository"
C1="$(git -C "$WORK" rev-parse HEAD)"
new_env
REPO_URL="file://$BARE"; REF="distro"
CL="$OC/metaswarm"
inst
check "fresh install exits 0 (last line: $(printf '%s' "$OUT" | tail -1))" "$RC"
[ -d "$CL/.git" ] && [ "$(git -C "$CL" rev-parse HEAD)" = "$C1" ] && pass "cloned into <opencode dir>/metaswarm at the ref" || fail "clone: $(git -C "$CL" rev-parse HEAD 2>&1 | head -1)"
has "distro" && has "$(git -C "$CL" rev-parse --short HEAD)" && pass "prints the ref and the short commit" || fail "prints the ref and the short commit"
ok "skill links resolve into the clone" links_into "$OC/skills" "$CL/skills"
ok "command links resolve into the clone" links_into "$OC/commands" "$CL/commands"
[ "$(readlink "$OC/plugins/metaswarm-session.js")" = "$CL/.opencode/plugins/metaswarm-session.js" ] && pass "plugin link resolves into the clone" || fail "plugin link"
[ "$(names "$OC/agents")" = "$(names "$CL/agents")" ] && pass "agents generated from the clone" || fail "agents generated from the clone"
[ "$(json_get "$OC/opencode.json" instructions.0)" = "$CL/.opencode/OPENCODE.md" ] && [ "$(json_get "$OC/opencode.json" mcp.servers.beads.command.1)" = "$CL/.opencode/mcp/beads-mcp-server.ts" ] && pass "config points into the clone" || fail "config points into the clone"
has "PLUGIN_ROOT='$CL'" && pass "scoped function uses the clone path" || fail "scoped function uses the clone path"
[ -z "$(git -C "$CL" status --porcelain)" ] && pass "the clone's work tree stays clean" || fail "clone dirty: $(git -C "$CL" status --porcelain | head -3 | tr '\n' ' ')"
ln -s "$TMP_BASE/e$N" "$OC/skills/my-own"       # a user link that must survive everything below
# second commit: one skill, one command and one agent go away
(cd "$WORK" && $G rm -q -r skills/status commands/prime.md "agents/$A2" && $G commit -q -m two && $G push -q "$BARE" distro) >/dev/null 2>&1 || fail "could not push the second commit"
C2="$(git -C "$WORK" rev-parse HEAD)"
installed="$(snap "$OC")"
# wrong ref
REF="no-such-branch"; inst; REF="distro"
[ "$RC" != "0" ] && [ "$RC" != "64" ] && pass "unknown ref: non-zero exit" || fail "unknown ref: rc=$RC"
[ "$(snap "$OC")" = "$installed" ] && [ "$(git -C "$CL" rev-parse HEAD)" = "$C1" ] && pass "unknown ref: links, agents and clone untouched" || fail "unknown ref changed the install"
# local modification that blocks the checkout
echo "local edit" >> "$CL/commands/prime.md"
inst
[ "$RC" != "0" ] && [ "$RC" != "64" ] && [ "$(snap "$OC")" = "$installed" ] && pass "local changes block the checkout: non-zero exit, install untouched" || fail "blocked checkout: rc=$RC"
grep -q 'local edit' "$CL/commands/prime.md" && pass "local changes block the checkout: the edit is kept" || fail "local edit was discarded"
printf '%s\n' "$OUT" | grep -q 'prime.md' && pass "git's error names the file" || fail "git's error not shown: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
git -C "$CL" checkout -q -- commands/prime.md
# real update
inst
check "update exits 0 (last line: $(printf '%s' "$OUT" | tail -1))" "$RC"
[ "$(git -C "$CL" rev-parse HEAD)" = "$C2" ] && pass "clone is at the new commit" || fail "clone HEAD: $(git -C "$CL" rev-parse HEAD)"
has "$(git -C "$CL" rev-parse --short HEAD)" && pass "prints the new short commit" || fail "prints the new short commit"
[ ! -L "$OC/skills/status" ] && [ ! -e "$OC/skills/status" ] && [ ! -L "$OC/commands/prime.md" ] && pass "links of the deleted skill and command are gone" || fail "stale links after update"
[ ! -e "$OC/agents/$A2" ] && pass "generated file of the deleted agent is gone" || fail "orphan agent remains"
[ -L "$OC/skills/start" ] && [ -L "$OC/commands/status.md" ] && [ -L "$OC/commands/start-task.md" ] && [ -f "$OC/agents/$A1" ] && [ -L "$OC/plugins/metaswarm-session.js" ] && [ -f "$OC/opencode.json" ] && pass "everything else is intact" || fail "update removed too much"
[ "$(readlink "$OC/skills/my-own")" = "$TMP_BASE/e$N" ] && pass "user symlink survives the update" || fail "user symlink survives the update"
! has '"instructions"' && pass "update prints no config snippet" || fail "update printed a config snippet"
# documented removal of the links
(cd "$CWD" && find "$OC/skills" "$OC/commands" "$OC/plugins" -maxdepth 1 -type l -lname "$OC/metaswarm/*" -delete)
[ "$(names "$OC/skills")" = "my-own" ] && [ -z "$(names "$OC/commands")" ] && [ -z "$(names "$OC/plugins")" ] && pass "documented find -lname removal deletes exactly the metaswarm links" || fail "documented removal: $(names "$OC/skills" | tr '\n' ' ')"
RC=0; OUT="$(cd "$CWD" && bash "$CL/.opencode/lib/generate-agents.sh" clean --dest "$OC/agents" 2>&1)" || RC=$?
[ "$RC" = "0" ] && [ -z "$(names "$OC/agents")" ] && pass "documented agent removal (generate-agents.sh clean --dest) empties agents/" || fail "documented agent removal: rc=$RC"
# an existing directory that is not a git work tree
new_env; mkdir -p "$OC/metaswarm/skills"; echo "precious" > "$OC/metaswarm/notes.txt"
before="$(cd "$OC" && find . | sort)"
inst
[ "$RC" != "0" ] && [ "$RC" != "64" ] && pass "clone path is a plain directory: non-zero exit" || fail "plain directory: rc=$RC"
[ "$(cd "$OC" && find . | sort)" = "$before" ] && [ "$(cat "$OC/metaswarm/notes.txt")" = "precious" ] && pass "clone path is a plain directory: nothing removed or added" || fail "plain directory was changed"
has "$OC/metaswarm" && pass "clone path is a plain directory: error names it" || fail "plain directory error: $(printf '%s' "$OUT" | tail -2)"
# a plain directory inside someone else's git repository is still not a clone
new_env; mkdir -p "$OC/metaswarm"; echo "precious" > "$OC/metaswarm/notes.txt"
(cd "$X" && $G init -q && $G remote add origin "file://$BARE") >/dev/null 2>&1   # e.g. a dotfiles repository
inst
[ "$RC" != "0" ] && [ "$(cat "$OC/metaswarm/notes.txt")" = "precious" ] && [ ! -e "$OC/skills" ] && pass "plain directory inside an outer git repository: refused" || fail "plain dir inside outer repo: rc=$RC"
! git -C "$X" rev-parse -q --verify HEAD >/dev/null 2>&1 && [ ! -e "$X/.git/FETCH_HEAD" ] && pass "the outer repository was not fetched into or checked out" || fail "git ran against the outer repository"
# unreachable repository on a fresh install
new_env; REPO_URL="file://$TMP_BASE/no-such-repo.git"
inst
[ "$RC" != "0" ] && [ ! -e "$OC/skills" ] && [ ! -e "$OC/opencode.json" ] && pass "failed clone: non-zero exit, nothing installed" || fail "failed clone: rc=$RC"
unset REPO_URL REF

echo "Test 11: generator failure is not hidden"
new_env
TB="$TMP_BASE/e$N/tree"; cp -R "$T" "$TB"
printf '{ "name": "metaswarm" }\n' > "$TB/.claude-plugin/plugin.json"   # no version: generator exits 3
inst --from "$TB"
[ "$RC" != "0" ] && [ "$RC" != "64" ] && pass "non-zero exit when the generator fails" || fail "generator failure hidden: rc=$RC"
[ -L "$OC/skills/start" ] && [ -f "$OC/opencode.json" ] && has "opencode() {" && pass "the remaining steps still run and report" || fail "remaining steps skipped after a generator failure"
printf '%s\n' "$OUT" | grep -qi 'agent' && pass "the failure is reported" || fail "the failure is reported"

echo "Test 12: --migrate-project"
# mk_old <dir>: a copy of the old-layout fixture
mk_old() { mkdir -p "$1"; cp -R "$OLD_LAYOUT/." "$1/"; }
MOVED="opencode.json .opencode/commands .opencode/agents .opencode/skills .opencode/OPENCODE.md .opencode/plugins/metaswarm-session.js scripts/beads-mcp-server.ts"
KEPT="README.md src/app.js scripts/keep.sh .opencode/plugins/my-plugin.js .opencode/notes.md"
new_env; PR="$TMP_BASE/e$N/proj"; mk_old "$PR"
for p in $MOVED $KEPT; do [ -e "$OLD_LAYOUT/$p" ] || fail "fixture is missing $p"; done
inst --migrate-project "$PR"
check "old layout: exits 0" "$RC"
BK="$(ls -d "$PR"/.metaswarm/migrate-backup-* 2>/dev/null | head -1)" || true
[ -n "$BK" ] && [ "$(ls -d "$PR"/.metaswarm/migrate-backup-* | wc -l | tr -d ' ')" = "1" ] && pass "one backup directory under .metaswarm/" || fail "backup directory: $(ls "$PR/.metaswarm" 2>&1 | tr '\n' ' ')"
case "$(basename "${BK:-none}")" in migrate-backup-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) pass "backup directory name carries a YYYYmmdd-HHMMSS timestamp" ;; *) fail "backup directory name: $(basename "${BK:-none}")" ;; esac
moved_bad=0
for p in $MOVED; do
  { [ ! -e "$PR/$p" ] && [ ! -L "$PR/$p" ] && [ -e "$BK/$p" ] && diff -r "$OLD_LAYOUT/$p" "$BK/$p" >/dev/null; } || { moved_bad=1; echo "    not moved intact: $p"; }
  has "$p" || { moved_bad=1; echo "    not listed: $p"; }
done
check "every old-layout item moved with the same relative path and bytes, and listed" "$moved_bad"
kept_bad=0
for p in $KEPT; do { [ -f "$PR/$p" ] && cmp -s "$OLD_LAYOUT/$p" "$PR/$p" && [ ! -e "$BK/$p" ]; } || { kept_bad=1; echo "    touched: $p"; }; done
check "the user's other files are untouched" "$kept_bad"
[ "$(cd "$BK" && find . -type f | wc -l | tr -d ' ')" = "$(cd "$OLD_LAYOUT" && for p in $MOVED; do find "$p" -type f; done | wc -l | tr -d ' ')" ] && pass "nothing else was moved" || fail "backup holds unexpected files"
[ ! -e "$PR/opencode.json" ] && pass "no opencode.json left in the project" || fail "opencode.json left"
has "/setup" && has "Re-run" && pass "message says to run /setup and choose Re-run" || fail "next-step message: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
[ ! -e "$OC" ] && [ -z "$(ls -A "$X")" ] && pass "migration installs nothing" || fail "migration touched the OpenCode directory"
inst --migrate-project "$PR"
[ "$RC" = "0" ] && [ "$(ls -d "$PR"/.metaswarm/migrate-backup-* | wc -l | tr -d ' ')" = "1" ] && pass "second run: nothing left to migrate, no second backup" || fail "second migrate run: rc=$RC"
# same-name agent without a generated-by header, no {file: config
new_env; PR="$TMP_BASE/e$N/proj"; mkdir -p "$PR/.opencode/agents" "$PR/src"
write_user_agent "$PR/.opencode/agents/$A1"; echo "mine" > "$PR/.opencode/agents/my-helper.md"; echo "x" > "$PR/src/a.txt"
printf '{ "theme": "mine" }\n' > "$PR/opencode.json"
inst --migrate-project "$PR" --from "$T"
BK="$(ls -d "$PR"/.metaswarm/migrate-backup-* 2>/dev/null | head -1)" || true
[ "$RC" = "0" ] && [ -n "$BK" ] && [ -f "$BK/.opencode/agents/$A1" ] && [ ! -e "$PR/.opencode/agents" ] && pass "header-less agent with a metaswarm agent's name triggers the move" || fail "same-name agent trigger: rc=$RC $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
[ -f "$BK/opencode.json" ] && [ -f "$BK/.opencode/agents/my-helper.md" ] && [ -f "$PR/src/a.txt" ] && pass "same-name trigger moves the listed items, leaves the rest" || fail "same-name trigger moved the wrong set"
# the same project without a checkout to compare names against: not detected
new_env; PR="$TMP_BASE/e$N/proj"; mkdir -p "$PR/.opencode/agents"
write_user_agent "$PR/.opencode/agents/$A1"
inst --migrate-project "$PR"
[ "$RC" = "0" ] && [ ! -e "$PR/.metaswarm" ] && [ -f "$PR/.opencode/agents/$A1" ] && pass "no checkout to compare with: a current agent name alone does not trigger" || fail "no-checkout case: rc=$RC"
# ... but the installed clone is used when present
mkdir -p "$OC/metaswarm/agents"; cp "$T/agents/$A1" "$OC/metaswarm/agents/$A1"
inst --migrate-project "$PR"
[ "$RC" = "0" ] && [ -d "$PR/.metaswarm" ] && [ ! -e "$PR/.opencode/agents" ] && pass "agent names come from the installed clone when --from is not given" || fail "installed-clone names: rc=$RC"
# legacy agent names trigger without any checkout
for legacy in coder researcher code-review; do
  new_env; PR="$TMP_BASE/e$N/proj"; mkdir -p "$PR/.opencode/agents"
  write_user_agent "$PR/.opencode/agents/$legacy-agent.md"
  inst --migrate-project "$PR"
  [ "$RC" = "0" ] && [ -f "$(ls -d "$PR"/.metaswarm/migrate-backup-* 2>/dev/null | head -1)/.opencode/agents/$legacy-agent.md" ] && pass "legacy name $legacy-agent.md triggers without a checkout" || fail "legacy name $legacy-agent.md: rc=$RC"
done
# clean project
new_env; PR="$TMP_BASE/e$N/proj"; mkdir -p "$PR/.opencode/agents" "$PR/.opencode/commands" "$PR/scripts"
echo "mine" > "$PR/.opencode/agents/my-helper.md"; echo "mine" > "$PR/.opencode/commands/deploy.md"
printf '{ "theme": "mine" }\n' > "$PR/opencode.json"; echo "// mine" > "$PR/scripts/beads-mcp-server.ts"
before="$(snap "$PR")"
inst --migrate-project "$PR" --from "$T"
[ "$RC" = "0" ] && [ "$(snap "$PR")" = "$before" ] && [ ! -e "$PR/.metaswarm" ] && pass "clean project: exit 0, nothing moved, no backup directory" || fail "clean project: rc=$RC"
printf '%s\n' "$OUT" | grep -qi 'not an old' && pass "clean project: says it is not an old layout" || fail "clean project message: $OUT"
# a generated per-role agent (metaswarm-agents.sh generate --host opencode) is not an old layout
new_env; PR="$TMP_BASE/e$N/proj"; mkdir -p "$PR/.metaswarm"
git -C "$PR" init -q
printf '# metaswarm models v1\nroles:\n  coder:\n    claude: sonnet\n    opencode: anthropic/claude-sonnet-4-5\n' > "$PR/.metaswarm/models.yaml"
GRC=0; GOUT="$(cd "$PR" && PLUGIN_ROOT="$ROOT" bash "$ROOT/bin/metaswarm-agents.sh" generate --host opencode 2>&1)" || GRC=$?
[ "$GRC" = "0" ] && grep -q '^<!-- generated-by: metaswarm ' "$PR/.opencode/agents/coder.md" 2>/dev/null && [ -f "$ROOT/agents/coder.md" ] && pass "setup: generated project agent shares its name with a metaswarm agent" || fail "setup: generate --host opencode: rc=$GRC $GOUT"
before="$(snap "$PR/.opencode")"
inst --migrate-project "$PR" --from "$ROOT"
[ "$RC" = "0" ] && [ "$(snap "$PR/.opencode")" = "$before" ] && [ -z "$(ls -d "$PR"/.metaswarm/migrate-backup-* 2>/dev/null)" ] && pass "generated (header-bearing) project agent does not trigger" || fail "generated agent triggered a migration: rc=$RC"
# the same file with the header stripped does
grep -v '^<!-- generated-by: metaswarm ' "$PR/.opencode/agents/coder.md" > "$PR/.opencode/agents/coder.md.tmp" && mv "$PR/.opencode/agents/coder.md.tmp" "$PR/.opencode/agents/coder.md"
inst --migrate-project "$PR" --from "$ROOT"
[ "$RC" = "0" ] && [ -n "$(ls -d "$PR"/.metaswarm/migrate-backup-* 2>/dev/null)" ] && [ -f "$PR/.metaswarm/models.yaml" ] && pass "the same agent without its header triggers; models.yaml stays" || fail "header-stripped agent: rc=$RC"
# errors
new_env
inst --migrate-project "$TMP_BASE/e$N/no-such-project"
[ "$RC" != "0" ] && [ "$RC" != "64" ] && pass "missing project directory: non-zero exit" || fail "missing project directory: rc=$RC"

echo "Test 13: usage"
new_env
usage_case() { local d="$1"; shift; inst "$@"; [ "$RC" = "64" ] && [ ! -e "$OC" ] && has "--from" && pass "$d" || fail "$d: rc=$RC"; }
usage_case "unknown option" --bogus
usage_case "--uninstall is not an option" --uninstall
usage_case "stray positional argument" extra
usage_case "--from without a value" --from
usage_case "--migrate-project without a value" --migrate-project
usage_case "unknown option after a valid one" --from "$T" --frobnicate
inst --help
[ "$RC" = "0" ] && has "--from" && has "--migrate-project" && has "METASWARM_REF" && [ ! -e "$OC" ] && pass "--help prints usage, exit 0, installs nothing" || fail "--help: rc=$RC"

echo ""
echo "Results: $PASS passed, $FAIL failed"
DONE=1
[ "$FAIL" -eq 0 ] || exit 1
