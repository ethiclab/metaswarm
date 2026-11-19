#!/usr/bin/env bash
# tests/opencode/test-opencode-plugin.sh
# Tests for the two OpenCode runtime files that the installer links and configures:
#   .opencode/plugins/metaswarm-session.js   session plugin (OpenCode 1.x and 2.x)
#   .opencode/mcp/beads-mcp-server.ts        BEADS MCP server, run as `node <file>`
#
# The assertions are in helpers/*.mjs and run under node; this wrapper builds the
# fixtures and counts the PASS/FAIL lines. No OpenCode binary, no bd, no network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PHYS_ROOT="$(cd "$ROOT" && pwd -P)"
PLUGIN="$ROOT/.opencode/plugins/metaswarm-session.js"
SERVER="$ROOT/.opencode/mcp/beads-mcp-server.ts"
HELPERS="$SCRIPT_DIR/helpers"
PASS=0
FAIL=0
TMP_BASE="$(mktemp -d)"
# bash 3.2 exits with the EXIT trap's status (0) when `set -u` aborts the script,
# so a crash would look like a pass. DONE is set only after the summary runs.
DONE=0
trap 'rm -rf "${TMP_BASE:?}"; [ "$DONE" = 1 ] || { echo "ABORTED before summary" >&2; exit 1; }' EXIT

unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT NODE_OPTIONS

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# count_lines <pattern> <text>: number of lines of <text> that start with <pattern>
count_lines() { printf '%s\n' "$2" | grep -c "^$1" || true; }

# run_checks <label> <node args...>: run a helper, print its lines, add its counts.
# A helper that crashes, or that reports nothing, is a failure.
run_checks() {
  local label="$1" out rc=0 p f
  shift
  out="$(node "$@" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  p="$(count_lines '  PASS: ' "$out")"
  f="$(count_lines '  FAIL: ' "$out")"
  PASS=$((PASS + p))
  FAIL=$((FAIL + f))
  if [ "$rc" != 0 ]; then fail "$label: helper exited $rc"; fi
  if [ "$p" = 0 ] && [ "$f" = 0 ]; then fail "$label: helper reported no checks"; fi
}

command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 1; }
PHYS_TMP="$(cd "$TMP_BASE" && pwd -P)"

echo "Test 1: the files exist and carry no trace of the old per-project setup"
[ -f "$PLUGIN" ] && pass "plugin file exists" || fail "plugin file missing: $PLUGIN"
[ -f "$SERVER" ] && pass "MCP server file exists" || fail "MCP server file missing: $SERVER"
for word in "MANDATORY_FILES" "npx metaswarm"; do
  if [ -f "$PLUGIN" ] && ! grep -qF -- "$word" "$PLUGIN"; then pass "plugin source does not contain '$word'"; else fail "plugin source contains '$word' (or is missing)"; fi
done
if [ -f "$PLUGIN" ] && ! grep -qE "^[[:space:]]*import .* from [\"'][^n.]|require\\(" "$PLUGIN"; then pass "plugin imports only node: built-ins"; else fail "plugin imports something that is not a node: built-in"; fi
if [ -f "$SERVER" ] && ! grep -E "^[[:space:]]*import " "$SERVER" | grep -qvE "from \"node:[a-z_/]+\";"; then pass "MCP server imports only node: built-ins"; else fail "MCP server imports something that is not a node: built-in"; fi
# Node strips types without transforming: these constructs would not run.
if [ -f "$SERVER" ] && ! grep -qE "^[[:space:]]*(export[[:space:]]+)?(declare[[:space:]]+)?(const[[:space:]]+)?(enum|namespace|module)[[:space:]]+[A-Za-z_]|constructor\\([^)]*(public|private|protected|readonly)[[:space:]]" "$SERVER"; then pass "MCP server uses only erasable TypeScript syntax"; else fail "MCP server uses enum, namespace or parameter properties"; fi
if [ -f "$SERVER" ] && ! grep -qiE "bd sync([^[:alnum:]_-]|$)|\"sync\"" "$SERVER"; then pass "MCP server does not use the removed 'bd sync'"; else fail "MCP server still refers to 'bd sync'"; fi

echo "Test 2: plugin imported from the repository"
if [ -f "$PLUGIN" ]; then
  mkdir -p "$TMP_BASE/w2"
  run_checks "plugin (direct)" "$HELPERS/plugin-checks.mjs" "$PLUGIN" "$PHYS_ROOT" "$TMP_BASE/w2"
else
  fail "plugin (direct): no plugin file"
fi

echo "Test 3: plugin imported through the installer's symlink"
# The layout of a real install: <opencode dir>/plugins/<file> -> <clone>/.opencode/plugins/<file>,
# here with the clone itself behind a symlinked directory. The root must be the
# physical clone, whatever the working directory is.
if [ -f "$PLUGIN" ]; then
  mkdir -p "$TMP_BASE/real/clone/.opencode/plugins" "$TMP_BASE/real/clone/bin" "$TMP_BASE/oc/plugins" "$TMP_BASE/w3" "$TMP_BASE/w3p" "$TMP_BASE/w3c" "$TMP_BASE/elsewhere"
  cp "$PLUGIN" "$TMP_BASE/real/clone/.opencode/plugins/metaswarm-session.js"
  # what makes a directory a metaswarm checkout for the plugin
  : > "$TMP_BASE/real/clone/bin/metaswarm-agents.sh"
  : > "$TMP_BASE/real/clone/.opencode/install.sh"
  ln -s "$TMP_BASE/real" "$TMP_BASE/alias"
  ln -s "$TMP_BASE/alias/clone/.opencode/plugins/metaswarm-session.js" "$TMP_BASE/oc/plugins/metaswarm-session.js"
  (cd "$TMP_BASE/elsewhere" && run_checks "plugin (symlink)" "$HELPERS/plugin-checks.mjs" "$TMP_BASE/oc/plugins/metaswarm-session.js" "$PHYS_TMP/real/clone" "$TMP_BASE/w3"; echo "$PASS $FAIL" > "$TMP_BASE/counts")
  read -r PASS FAIL < "$TMP_BASE/counts"
  # A loader that keeps the symlink path in import.meta.url (node --preserve-symlinks
  # here) leaves the resolving to the plugin.
  (cd "$TMP_BASE/elsewhere" && run_checks "plugin (symlink kept by the loader)" --preserve-symlinks "$HELPERS/plugin-checks.mjs" "$TMP_BASE/oc/plugins/metaswarm-session.js" "$PHYS_TMP/real/clone" "$TMP_BASE/w3p"; echo "$PASS $FAIL" > "$TMP_BASE/counts")
  read -r PASS FAIL < "$TMP_BASE/counts"
  # Copied instead of linked: three directories up is the user's config directory,
  # not a checkout, and must not be exported as PLUGIN_ROOT.
  mkdir -p "$TMP_BASE/cfg/opencode/plugins" "$TMP_BASE/cfg/bin"
  cp "$PLUGIN" "$TMP_BASE/cfg/opencode/plugins/metaswarm-session.js"
  (cd "$TMP_BASE/elsewhere" && run_checks "plugin (stray copy)" "$HELPERS/plugin-checks.mjs" "$TMP_BASE/cfg/opencode/plugins/metaswarm-session.js" "-" "$TMP_BASE/w3c"; echo "$PASS $FAIL" > "$TMP_BASE/counts")
  read -r PASS FAIL < "$TMP_BASE/counts"
else
  fail "plugin (symlink): no plugin file"
fi

echo "Test 4: BEADS MCP server over stdio"
NODE_VER="$(node -p 'process.versions.node')"
NODE_MAJOR="${NODE_VER%%.*}"; NODE_REST="${NODE_VER#*.}"; NODE_MINOR="${NODE_REST%%.*}"
if [ "$NODE_MAJOR" -lt 22 ] || { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -lt 18 ]; }; then
  echo "  SKIP: node $NODE_VER cannot run a .ts file directly (needs >= 22.18); the MCP handshake is not tested"
elif [ ! -f "$SERVER" ]; then
  fail "MCP: no server file"
else
  PROJ="$TMP_BASE/proj"; STUB="$TMP_BASE/stub"
  mkdir -p "$PROJ/.beads/knowledge" "$STUB"
  printf '%s\n' '{"id": "pattern-1", "type": "pattern", "fact": "first"}' '' '{"id": "pattern-2", "type": "pattern", "fact": "second"}' > "$PROJ/.beads/knowledge/patterns.jsonl"
  printf '%s\n' '{"id": "gotcha-1", "type": "gotcha", "fact": "third"}' 'this line is not JSON' > "$PROJ/.beads/knowledge/gotchas.jsonl"
  printf '%s\n' '{"id": "api-1", "type": "api_behavior", "fact": "fourth"}' > "$PROJ/.beads/knowledge/api-behaviors.jsonl"
  echo "not a knowledge file" > "$PROJ/.beads/knowledge/README.md"
  # must be skipped without blocking: a FIFO, and a file larger than the read cap
  mkfifo "$PROJ/.beads/knowledge/fifo.jsonl"
  { echo '{"id": "big-first", "type": "pattern"}'; head -c 6000000 /dev/zero | tr '\0' ' '; echo; echo '{"id": "big-last", "type": "pattern"}'; } > "$PROJ/.beads/knowledge/zz-big.jsonl"
  mkdir -p "$TMP_BASE/empty-home"
  cat > "$STUB/bd" <<'STUB_EOF'
#!/bin/sh
# Fake bd: logs "<cwd>|<argc>|<args>" and answers a few subcommands.
PATH="$PATH:/usr/bin:/bin"
printf '%s|%s|%s\n' "$(pwd -P)" "$#" "$*" >> "$STUB_LOG"
case "$*" in
  "ready --json") echo '[{"id":"stub-1","title":"Stub issue","status":"open"}]' ;;
  "show missing-1 --json") echo "Error: no issue found matching missing-1" >&2; exit 1 ;;
  "show partial-1 --json") echo "partial-out"; echo "partial-err" >&2; exit 3 ;;
  "show stdin-1 --json") if IFS= read -r line; then echo "stdin:got"; else echo "stdin:eof"; fi ;;
  "show slow-1 --json") exec sleep 30 ;;
  "show big-1 --json") head -c 12000000 /dev/zero | tr '\0' 'x' ;;
  "show "*) echo "{\"id\":\"$2\",\"title\":\"shown $2\"}" ;;
  "prime") echo "# Stub workflow reference" ;;
  "dolt pull") if [ -e "$STUB_LOG.failpull" ]; then echo "pull-failed" >&2; exit 1; fi; echo "pulled-ok" ;;
  "dolt push") echo "pushed-ok" ;;
  *) echo "stub bd: unknown command: $*" >&2; exit 2 ;;
esac
STUB_EOF
  chmod +x "$STUB/bd"
  run_checks "MCP" "$HELPERS/mcp-checks.mjs" "$SERVER" "$PROJ" "$STUB" "$TMP_BASE/stub.log"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
DONE=1
[ "$FAIL" -eq 0 ] || exit 1
