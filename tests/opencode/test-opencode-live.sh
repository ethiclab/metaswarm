#!/usr/bin/env bash
# tests/opencode/test-opencode-live.sh
# Live check of the OpenCode install against real OpenCode binaries: installs with
# .opencode/install.sh into an isolated HOME and asks OpenCode itself what it loaded.
#
#   bash tests/opencode/test-opencode-live.sh
#   OPENCODE_BIN=<path> OPENCODE2_BIN=<path> bash tests/opencode/test-opencode-live.sh
#   OPENCODE_BIN="$(command -v opencode)" bash tests/opencode/test-opencode-live.sh
#
# Binaries: $OPENCODE_BIN and $OPENCODE2_BIN, or `opencode` on PATH when neither is
# set. Nothing is installed or downloaded here. Each binary's `--version` picks the
# half that runs for it, whichever variable named it:
#   1.x                      -> CLI half (`debug config`, `agent list`, `debug skill`, `mcp list`),
#                               then `serve` and one shell command in a session, which is what
#                               loads the session plugin on 1.x
#   2.x or 0.0.0-beta-<n>    -> server half (`serve` + its HTTP API), plus two extra cases
# No binary: the test skips with exit 0. So does an `opencode` found only on PATH whose
# version is not recognised. METASWARM_LIVE_REQUIRED=1 turns both into failures and also
# requires that both halves ran.
#
# No model, API key or session is used. HOME and the XDG directories are temp
# directories; the servers started here are stopped by PID on exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL="$ROOT/.opencode/install.sh"
PASS=0
FAIL=0
PIDS=""
# physical path: OpenCode reports resolved paths, and macOS temp directories sit behind a symlink
TMP_BASE="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
  local p
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  for p in $PIDS; do wait "$p" 2>/dev/null; done
  chmod -R u+rwx "${TMP_BASE:?}" 2>/dev/null
  rm -rf "${TMP_BASE:?}"
}
# bash 3.2 exits with the EXIT trap's status (0) when `set -u` aborts the script,
# so a crash would look like a pass. DONE is set only after the summary runs.
DONE=0
# fd 9 is this script's own stderr: a signal can arrive while a command's stderr is redirected
exec 9>&2
trap 'cleanup; [ "$DONE" = 1 ] || { echo "ABORTED before summary" >&9; exit 1; }' EXIT
# Ctrl-C and kill stop the test (and, through the EXIT trap, the servers it started)
trap 'exit 130' INT
trap 'exit 143' TERM

REQUIRED="${METASWARM_LIVE_REQUIRED:-0}"
BIN_A="${OPENCODE_BIN:-}"
BIN_B="${OPENCODE2_BIN:-}"
FROM_PATH=0
if [ -z "$BIN_A" ] && [ -z "$BIN_B" ]; then
  BIN_A="$(command -v opencode 2>/dev/null || true)"
  FROM_PATH=1
fi

echo "Running OpenCode live tests..."
if [ -z "$BIN_A" ] && [ -z "$BIN_B" ] && [ "$REQUIRED" != 1 ]; then
  echo "  SKIP: no OpenCode binary (set OPENCODE_BIN and/or OPENCODE2_BIN, or put opencode on PATH)"
  echo ""
  echo "Results: 0 passed, 0 failed (skipped)"
  DONE=1
  exit 0
fi

unset OPENCODE_CONFIG_DIR PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
unset METASWARM_REPO_URL METASWARM_REF CDPATH extensionPath MS_PLUGIN NODE_OPTIONS
unset OPENCODE_CONFIG OPENCODE_CONFIG_CONTENT OPENCODE_SERVER_PASSWORD OPENCODE_SERVER_USERNAME

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
skip() { echo "  SKIP: $1"; }

# The exact numbers of metaswarm agents, linked commands and skills. They are written
# here and nowhere else; the tree must agree with them.
EXPECT_AGENTS=23
EXPECT_COMMANDS=12
EXPECT_SKILLS=14
EXCLUDED="metaswarm-setup.md metaswarm-update-version.md update.md start.md"
START_TIMEOUT=120    # the first start of a binary in a new HOME can be slow
CALL_TIMEOUT=60
POLL_SECONDS=30      # the 2.x registries fill a few seconds after the server is up

WANT="$TMP_BASE/want"
mkdir -p "$WANT"
(cd "$ROOT/agents" && for f in *.md; do [ -f "$f" ] && echo "${f%.md}"; done | sort) > "$WANT/agents"
(cd "$ROOT/skills" && for d in */; do [ -f "${d}SKILL.md" ] && echo "${d%/}"; done | sort) > "$WANT/skills"
(cd "$ROOT/commands" && for f in *.md; do case " $EXCLUDED " in *" $f "*) ;; *) echo "${f%.md}" ;; esac; done | sort) > "$WANT/commands"
lines() { grep -c . "$1" || true; }

# A stub bd: the BEADS MCP server only needs to start; no tool is called here.
STUB="$TMP_BASE/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\necho "bd stub $*"\n' > "$STUB/bd"
chmod +x "$STUB/bd"
# metaswarm's bin/ must not already be on PATH: the 1.x half checks that the plugin adds it
PHYS_ROOT="$(cd "$ROOT" && pwd -P)"
CLEAN_PATH=""
OLD_IFS="$IFS"; IFS=:
for entry in $PATH; do
  case "$entry" in "$ROOT/bin"|"$PHYS_ROOT/bin"|"") continue ;; esac
  CLEAN_PATH="$CLEAN_PATH${CLEAN_PATH:+:}$entry"
done
IFS="$OLD_IFS"
PATH="$STUB:$CLEAN_PATH"
export PATH

# with_timeout <seconds> <command...>: `timeout` where there is one (GNU coreutils;
# `gtimeout` from Homebrew), else a watchdog in the shell (stock macOS has neither)
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
TIMEOUT_KILL=""
if [ -n "$TIMEOUT_BIN" ] && "$TIMEOUT_BIN" -k 1 5 true >/dev/null 2>&1; then TIMEOUT_KILL=1; fi
with_timeout() {
  local secs="$1" pid dog rc=0
  shift
  if [ -n "$TIMEOUT_BIN" ]; then
    # -k: a command that ignores TERM is killed 10 s later
    if [ -n "$TIMEOUT_KILL" ]; then "$TIMEOUT_BIN" -k 10 "$secs" "$@"; else "$TIMEOUT_BIN" "$secs" "$@"; fi
    return $?
  fi
  "$@" &
  pid=$!
  # The watchdog sleeps one second at a time and leaves by itself once the command is
  # gone, so no long sleep outlives this function.
  (
    left="$secs"
    while [ "$left" -gt 0 ]; do
      sleep 1
      kill -0 "$pid" 2>/dev/null || exit 0
      left=$((left - 1))
    done
    kill "$pid" 2>/dev/null
  ) >/dev/null 2>&1 </dev/null &
  dog=$!
  wait "$pid" || rc=$?
  kill "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  return "$rc"
}

# use_home <name>: switch to an isolated HOME; sets H and OC
use_home() {
  H="$TMP_BASE/$1/home"
  export HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" XDG_CACHE_HOME="$H/.cache" XDG_STATE_HOME="$H/.local/state"
  OC="$XDG_CONFIG_HOME/opencode"
  mkdir -p "$H"
}
# new_project <dir>: an empty git project
new_project() { mkdir -p "$1" && git -C "$1" init -q >/dev/null 2>&1; }

node_ok_for_mcp() {
  node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 18) ? 0 : 1)' 2>/dev/null
}

# --- Assertions on what OpenCode reports, written in node ---
#
# check.js <mode> <args...> prints "PASS: <text>" / "FAIL: <text>" lines (read by
# run_checks) or, for the `has-*` modes, only sets its exit status (used for polling).
CHECK="$TMP_BASE/check.js"
cat > "$CHECK" <<'CHECK_EOF'
const fs = require("fs");
const [mode, ...args] = process.argv.slice(2);
const out = (ok, text) => console.log(`${ok ? "PASS" : "FAIL"}: ${text}`);
const want = (f) => fs.readFileSync(f, "utf8").split("\n").filter(Boolean);
const json = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
// 2.x API responses are { location, data: [...] }; items are keyed by id or name
const data = (f) => {
  const d = json(f).data;
  if (!Array.isArray(d)) throw new Error(`${f}: no data array`);
  return d;
};
const key = (x) => (typeof x.id === "string" ? x.id : x.name);
const dups = (names) => [...new Set(names.filter((n, i) => names.indexOf(n) !== i))];
const show = (a) => (a.length ? a.join(", ") : "-");
const cut = (v) => { const s = JSON.stringify(v); return s === undefined ? "undefined" : s.slice(0, 200); };

// exactly(label, names, wantNames, count): every wanted name is there once, and
// `names` (the metaswarm-owned entries) holds nothing else
function exactly(label, names, w, count) {
  const missing = w.filter((n) => !names.includes(n));
  const extra = names.filter((n) => !w.includes(n));
  const d = dups(names);
  out(missing.length === 0, `${label}: every expected name is listed (missing: ${show(missing)})`);
  out(d.length === 0, `${label}: no name is listed twice (duplicates: ${show(d)})`);
  out(extra.length === 0 && names.length === Number(count), `${label}: exactly ${count} metaswarm entries (found ${names.length}, unexpected: ${show(extra)})`);
}
// present(label, all, wantNames, count): for listings whose entries do not say where
// they come from: the wanted names appear exactly once each, and no name twice
function present(label, all, w, count) {
  const mine = all.filter((n) => w.includes(n));
  const missing = w.filter((n) => !all.includes(n));
  const d = dups(all);
  out(missing.length === 0, `${label}: every expected name is listed (missing: ${show(missing)})`);
  out(d.length === 0, `${label}: no name is listed twice (duplicates: ${show(d)})`);
  out(mine.length === Number(count), `${label}: exactly ${count} metaswarm entries (found ${mine.length})`);
}
const generated = (x) => typeof x.system === "string" && x.system.includes("generated-by: metaswarm");

const modes = {
  // ---- 1.x ----
  "v1-config"([cfgFile, wantAgents, nAgents, wantCommands, nCommands, pluginLink]) {
    const c = json(cfgFile);
    exactly("1.x debug config commands", Object.keys(c.command || {}), want(wantCommands), nCommands);
    exactly("1.x debug config agents", Object.keys(c.agent || {}), want(wantAgents), nAgents);
    const bad = Object.entries(c.agent || {}).filter(([, a]) => a.mode !== "subagent").map(([n]) => n);
    out(bad.length === 0, `1.x debug config: every metaswarm agent has mode subagent (others: ${show(bad)})`);
    const plugins = (c.plugin || []).map((p) => (Array.isArray(p) ? p[0] : p)).filter((p) => typeof p === "string");
    // listed, not loaded: `debug config` does not load plugins (see v1-shell)
    out(plugins.some((p) => p.endsWith(pluginLink)), `1.x debug config lists the session plugin file (plugin: ${cut(c.plugin)})`);
  },
  "v1-instructions"([cfgFile, instructions]) {
    const c = json(cfgFile);
    out(Array.isArray(c.instructions) && c.instructions.includes(instructions), `1.x debug config: instructions holds ${instructions} (instructions: ${cut(c.instructions)})`);
  },
  // The answer of POST /session/<id>/shell: an assistant message whose tool part
  // carries the output of the command. The command printed PR=, BIN= and PATH= lines.
  "v1-shell"([file, root]) {
    const parts = json(file).parts;
    if (!Array.isArray(parts)) throw new Error("no parts in the shell answer");
    const text = parts.map((p) => (p.state && typeof p.state.output === "string" ? p.state.output : "")).join("\n");
    const val = (k) => { const l = text.split("\n").find((x) => x.startsWith(k + "=")); return l === undefined ? undefined : l.slice(k.length + 1); };
    out(val("PR") === root, `1.x session shell: the plugin's shell.env hook sets PLUGIN_ROOT to the checkout, ${root} (PLUGIN_ROOT: ${cut(val("PR"))})`);
    out((val("PATH") || "").split(":").includes(root + "/bin"), `1.x session shell: the hook puts ${root}/bin on PATH`);
    out(val("BIN") === root + "/bin/metaswarm-agents.sh", `1.x session shell: metaswarm-agents.sh resolves to the checkout's bin/ (found: ${cut(val("BIN"))})`);
  },
  "v1-agent-list"([file, wantAgents, nAgents]) {
    // one "<name> (<mode>)" line per agent, followed by its indented permission JSON
    const heads = fs.readFileSync(file, "utf8").split("\n").map((l) => /^(\S+) \((\w+)\)\s*$/.exec(l)).filter(Boolean);
    const w = want(wantAgents);
    present("1.x agent list", heads.map((m) => m[1]), w, nAgents);
    const notSub = heads.filter((m) => w.includes(m[1]) && m[2] !== "subagent").map((m) => `${m[1]} (${m[2]})`);
    const sub = heads.filter((m) => w.includes(m[1]) && m[2] === "subagent");
    out(notSub.length === 0 && sub.length === Number(nAgents), `1.x agent list: ${nAgents} metaswarm agents are listed as (subagent) (found ${sub.length}, others: ${show(notSub)})`);
  },
  "v1-skills"([file, wantSkills, nSkills, ocDir]) {
    const all = json(file);
    present("1.x debug skill", all.map((s) => s.name), want(wantSkills), nSkills);
    const mine = all.filter((s) => typeof s.location === "string" && s.location.startsWith(ocDir + "/"));
    exactly("1.x debug skill, entries under the OpenCode directory", mine.map((s) => s.name), want(wantSkills), nSkills);
  },
  // ---- 2.x ----
  "has-names"([file, wantFile]) {
    const all = data(file).map(key);
    process.exit(want(wantFile).every((n) => all.includes(n)) ? 0 : 1);
  },
  "has-mcp"([file]) {
    process.exit(data(file).some((m) => key(m) === "beads" && m.status && m.status.status === "connected") ? 0 : 1);
  },
  "has-plugin"([file]) {
    process.exit(data(file).some((p) => key(p) === "metaswarm-session" && p.state && p.state.status === "active") ? 0 : 1);
  },
  "has-model"([file, role]) {
    process.exit(data(file).some((a) => key(a) === role && a.model !== undefined && a.model !== null) ? 0 : 1);
  },
  "v2-agents"([label, file, wantAgents, nAgents]) {
    const all = data(file);
    present(`${label} /api/agent`, all.map(key), want(wantAgents), nAgents);
    exactly(`${label} /api/agent, generated by metaswarm`, all.filter(generated).map(key), want(wantAgents), nAgents);
    const w = want(wantAgents);
    const bad = all.filter((a) => w.includes(key(a)) && a.mode !== "subagent").map((a) => `${key(a)} (${a.mode})`);
    out(bad.length === 0, `${label} /api/agent: every metaswarm agent has mode subagent (others: ${show(bad)})`);
  },
  "v2-commands"([label, file, wantCommands, nCommands, excludedList]) {
    const all = data(file).map(key);
    present(`${label} /api/command`, all, want(wantCommands), nCommands);
    const leaked = excludedList.split(" ").map((f) => f.replace(/\.md$/, "")).filter((n) => all.includes(n));
    out(leaked.length === 0, `${label} /api/command: the excluded commands are not served (found: ${show(leaked)})`);
  },
  "v2-skills"([label, file, wantSkills, nSkills, ocDir]) {
    const all = data(file);
    present(`${label} /api/skill`, all.map(key), want(wantSkills), nSkills);
    const mine = all.filter((s) => typeof s.location === "string" && s.location.startsWith(ocDir + "/"));
    exactly(`${label} /api/skill, entries under the OpenCode directory`, mine.map(key), want(wantSkills), nSkills);
  },
  "v2-mcp"([label, file]) {
    const m = data(file).filter((x) => key(x) === "beads");
    out(m.length === 1 && m[0].status && m[0].status.status === "connected", `${label} /api/mcp: beads is connected (${cut(m)})`);
  },
  "v2-plugin"([label, file, pluginLink]) {
    const p = data(file).filter((x) => key(x) === "metaswarm-session");
    out(p.length === 1 && p[0].state && p[0].state.status === "active", `${label} /api/plugin: metaswarm-session is active (${cut(p.map((x) => x.state))})`);
    out(p.length === 1 && p[0].source && p[0].source.path === pluginLink, `${label} /api/plugin: it is loaded from the installed link (${cut(p.map((x) => x.source))})`);
  },
  // GET /api/config answers with a bare array of config documents: { type, path, info }
  "v2-config"([label, file, instructions]) {
    const docs = json(file);
    if (!Array.isArray(docs)) throw new Error("/api/config is not an array");
    const all = docs.flatMap((d) => (d.info && Array.isArray(d.info.instructions) ? d.info.instructions : []));
    out(all.includes(instructions), `${label} /api/config: instructions holds ${instructions} (instructions: ${cut(all)})`);
  },
  // the three listings of two installs name the same things
  "v2-same"([label, dirA, dirB]) {
    for (const f of ["agent", "command", "skill"]) {
      const a = data(`${dirA}/${f}.json`).map(key).sort();
      const b = data(`${dirB}/${f}.json`).map(key).sort();
      const onlyB = b.filter((n) => !a.includes(n));
      const onlyA = a.filter((n) => !b.includes(n));
      out(a.length === b.length && onlyA.length === 0 && onlyB.length === 0, `${label} /api/${f}: the same ${a.length} names as the --from install (only here: ${show(onlyB)}; only there: ${show(onlyA)})`);
    }
  },
  "v2-override"([label, file, role, model, otherRole, wantAgents, nAgents]) {
    const all = data(file);
    present(`${label} /api/agent`, all.map(key), want(wantAgents), nAgents);
    const r = all.filter((a) => key(a) === role);
    const [provider, ...rest] = model.split("/");
    const id = rest.join("/");
    const m = r.length === 1 ? r[0].model : undefined;
    const ok = m === model || (m && typeof m === "object" && [m.providerID, m.provider, m.providerId].includes(provider) && [m.id, m.modelID, m.modelId, m.model].includes(id));
    out(Boolean(ok), `${label} /api/agent: ${role} has the model of the project-level file, ${model} (model: ${cut(m)})`);
    out(r.length === 1 && r[0].mode === "subagent" && typeof r[0].system === "string" && r[0].system.includes("generated-by: metaswarm"), `${label} /api/agent: ${role} keeps its prompt and mode (mode: ${r.length === 1 ? r[0].mode : "?"})`);
    const o = all.filter((a) => key(a) === otherRole);
    out(o.length === 1 && (o[0].model === undefined || o[0].model === null), `${label} /api/agent: ${otherRole}, not overridden, has no model (model: ${cut(o.length === 1 ? o[0].model : "?")})`);
  },
};

try {
  if (!modes[mode]) throw new Error(`unknown mode ${mode}`);
  modes[mode](args);
} catch (e) {
  if (mode.startsWith("has-")) process.exit(1);
  out(false, `${mode}: ${e.message}`);
}
CHECK_EOF

# run_checks <mode> <args...>: run check.js and add its PASS/FAIL lines to the counts.
# A check that reports nothing is a failure.
run_checks() {
  local mode="$1" out line n=0
  out="$(node "$CHECK" "$@" 2>&1)" || true
  while IFS= read -r line; do
    case "$line" in
      "PASS: "*) pass "${line#PASS: }"; n=$((n + 1)) ;;
      "FAIL: "*) fail "${line#FAIL: }"; n=$((n + 1)) ;;
      "") ;;
      *) echo "    $line" ;;
    esac
  done <<EOF
$out
EOF
  [ "$n" -gt 0 ] || fail "$mode reported nothing"
}

# install_from_tree <label>: run the installer with --from the working tree into the current HOME
install_from_tree() {
  local rc=0
  (cd "$TMP_BASE" && bash "$INSTALL" --from "$ROOT" > "$H/install.out" 2>&1 </dev/null) || rc=$?
  [ "$rc" = 0 ] && pass "$1: install.sh --from the working tree exits 0" || fail "$1: install.sh --from exited $rc: $(tail -3 "$H/install.out" | tr '\n' ' ')"
  [ "$(ls "$OC/agents" 2>/dev/null | grep -c .)" = "$EXPECT_AGENTS" ] && [ "$(ls "$OC/commands" 2>/dev/null | grep -c .)" = "$EXPECT_COMMANDS" ] && [ "$(ls "$OC/skills" 2>/dev/null | grep -c .)" = "$EXPECT_SKILLS" ] \
    && pass "$1: the OpenCode directory holds $EXPECT_AGENTS agents, $EXPECT_COMMANDS commands, $EXPECT_SKILLS skills" \
    || fail "$1: installed $(ls "$OC/agents" 2>/dev/null | grep -c .) agents, $(ls "$OC/commands" 2>/dev/null | grep -c .) commands, $(ls "$OC/skills" 2>/dev/null | grep -c .) skills"
}

# --- Which binary is which ---

# version_of <binary>: sets VERSION (the x.y.z[-suffix] of `--version`) and LINE (1, 2 or empty)
version_of() {
  VERSION="$(cd "$TMP_BASE" && with_timeout "$CALL_TIMEOUT" "$1" --version 2>/dev/null </dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?' | head -1)"
  case "$VERSION" in
    1.*) LINE=1 ;;
    2.*|0.0.0-beta-*) LINE=2 ;;
    *) LINE="" ;;
  esac
}

# --- 1.x: the CLI ---

run_v1() {
  local bin="$1" out rc pw enc sid
  echo "OpenCode 1.x: $bin ($VERSION)"
  use_home v1
  out="$TMP_BASE/v1/out"
  mkdir -p "$out"
  new_project "$TMP_BASE/v1/proj"
  install_from_tree "1.x"
  cd "$TMP_BASE/v1/proj" || { fail "1.x: cannot enter the project"; return 0; }

  rc=0; with_timeout "$START_TIMEOUT" "$bin" debug config > "$out/config.out" 2> "$out/config.err" </dev/null || rc=$?
  [ "$rc" = 0 ] && pass "1.x debug config exits 0" || fail "1.x debug config exited $rc: $(tail -3 "$out/config.err" | tr '\n' ' ')"
  run_checks v1-config "$out/config.out" "$WANT/agents" "$EXPECT_AGENTS" "$WANT/commands" "$EXPECT_COMMANDS" "/plugins/metaswarm-session.js"
  run_checks v1-instructions "$out/config.out" "$ROOT/.opencode/OPENCODE.md"

  rc=0; with_timeout "$CALL_TIMEOUT" "$bin" agent list > "$out/agents.out" 2> "$out/agents.err" </dev/null || rc=$?
  [ "$rc" = 0 ] && pass "1.x agent list exits 0" || fail "1.x agent list exited $rc: $(tail -3 "$out/agents.err" | tr '\n' ' ')"
  run_checks v1-agent-list "$out/agents.out" "$WANT/agents" "$EXPECT_AGENTS"

  # to a file, never a pipe: 1.x cuts `debug skill` at 128 KiB when its stdout is a pipe
  rc=0; with_timeout "$CALL_TIMEOUT" "$bin" debug skill > "$out/skills.out" 2> "$out/skills.err" </dev/null || rc=$?
  [ "$rc" = 0 ] && pass "1.x debug skill exits 0" || fail "1.x debug skill exited $rc: $(tail -3 "$out/skills.err" | tr '\n' ' ')"
  run_checks v1-skills "$out/skills.out" "$WANT/skills" "$EXPECT_SKILLS" "$OC"

  if node_ok_for_mcp; then
    rc=0; with_timeout "$CALL_TIMEOUT" "$bin" mcp list > "$out/mcp.out" 2> "$out/mcp.err" </dev/null || rc=$?
    # colour codes sit between the name and the status
    if [ "$rc" = 0 ] && cat "$out/mcp.out" "$out/mcp.err" | sed "s/$(printf '\033')\[[0-9;]*m//g" | grep -Eq '(^|[[:space:]])beads[[:space:]]+connected([[:space:]]|$)'; then
      pass "1.x mcp list: beads is connected"
    else
      fail "1.x mcp list (exit $rc): $(cat "$out/mcp.out" "$out/mcp.err" | sed "s/$(printf '\033')\[[0-9;]*m//g" | tr '\n' ' ' | cut -c1-300)"
    fi
  else
    skip "1.x mcp list: node $(node --version 2>/dev/null) is older than 22.18 and cannot run the BEADS MCP server (.ts)"
  fi
  cd "$TMP_BASE" || true

  # The commands above do not load plugins on 1.x. A session's shell does: its
  # environment goes through the plugin's shell.env hook. No model is involved.
  if ! command -v curl >/dev/null 2>&1; then
    fail "1.x: curl is needed to query the server"
    return 0
  fi
  pw="$(node -e 'process.stdout.write(require("crypto").randomBytes(24).toString("hex"))')"
  if serve_start "$bin" v1 "listening on" "$pw"; then
    pass "1.x: serve started"
    enc="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$TMP_BASE/v1/proj")"
    curl -sS --max-time 20 -u "opencode:$SRV_PW" -X POST -H 'content-type: application/json' -d '{}' \
      -o "$out/session.json" "http://127.0.0.1:$SRV_PORT/session?directory=$enc" 2>> "$SRV_LOG.curl" || true
    sid="$(node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); if (typeof s.id === "string" && /^[A-Za-z0-9_-]+$/.test(s.id)) process.stdout.write(s.id);' "$out/session.json" 2>/dev/null || true)"
    if [ -n "$sid" ]; then
      pass "1.x: POST /session created a session"
      # single quotes: the session's shell expands the variables, not this one
      # shellcheck disable=SC2016
      curl -sS --max-time "$CALL_TIMEOUT" -u "opencode:$SRV_PW" -X POST -H 'content-type: application/json' \
        -d '{"agent":"build","command":"echo PR=$PLUGIN_ROOT; echo BIN=$(command -v metaswarm-agents.sh); echo PATH=$PATH"}' \
        -o "$out/shell.json" "http://127.0.0.1:$SRV_PORT/session/$sid/shell?directory=$enc" 2>> "$SRV_LOG.curl" || true
      run_checks v1-shell "$out/shell.json" "$PHYS_ROOT"
    else
      fail "1.x: POST /session gave no session id: $(head -c 300 "$out/session.json" 2>/dev/null | tr '\n' ' ')"
    fi
  else
    server_failed "1.x"
  fi
  serve_stop
}

# --- 2.x: the server and its HTTP API ---

SRV_PORT=""
SRV_PW=""
SRV_LOG=""
SRV_PID=""
# serve_start <binary> <name> <ready text> [password]: start `serve` in the current
# HOME with cwd $TMP_BASE/<name>/proj and wait for <ready text> in its log. 2.x prints
# its own password ("server password <pw>"); 1.x takes one from the environment.
serve_start() {
  local bin="$1" ready="$3" pw="${4:-}" i
  SRV_LOG="$TMP_BASE/$2/serve.log"
  SRV_PW=""
  SRV_PORT="$(node -e 'const s = require("net").createServer(); s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });')"
  if [ -n "$pw" ]; then
    (cd "$TMP_BASE/$2/proj" && OPENCODE_SERVER_PASSWORD="$pw" exec "$bin" serve --port "$SRV_PORT" > "$SRV_LOG" 2>&1 </dev/null) &
  else
    (cd "$TMP_BASE/$2/proj" && exec "$bin" serve --port "$SRV_PORT" > "$SRV_LOG" 2>&1 </dev/null) &
  fi
  SRV_PID=$!
  PIDS="$PIDS $SRV_PID"
  i=0
  while [ "$i" -lt "$START_TIMEOUT" ]; do
    grep -q "$ready" "$SRV_LOG" 2>/dev/null && break
    kill -0 "$SRV_PID" 2>/dev/null || break
    sleep 1
    i=$((i + 1))
  done
  grep -q "$ready" "$SRV_LOG" 2>/dev/null || return 1
  if [ -n "$pw" ]; then
    SRV_PW="$pw"
  else
    SRV_PW="$(grep 'server password' "$SRV_LOG" 2>/dev/null | head -1 | awk '{ print $NF }')"
  fi
  [ -n "$SRV_PW" ]
}
serve_stop() {
  [ -n "$SRV_PID" ] || return 0
  kill "$SRV_PID" 2>/dev/null
  wait "$SRV_PID" 2>/dev/null
  SRV_PID=""
}
# api <method> <endpoint> <project dir> <output file>
api() {
  local enc
  enc="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$3")"
  curl -sS --max-time 20 -u "opencode:$SRV_PW" -X "$1" -o "$4" "http://127.0.0.1:$SRV_PORT/api/$2?location%5Bdirectory%5D=$enc" 2>> "$SRV_LOG.curl"
}
# poll <endpoint> <project dir> <output file> <check.js has-* mode> <args...>: fetch until the check holds
poll() {
  local ep="$1" dir="$2" file="$3" i=0
  shift 3
  while :; do
    api GET "$ep" "$dir" "$file" && node "$CHECK" "$@" 2>/dev/null && return 0
    i=$((i + 1))
    [ "$i" -lt "$POLL_SECONDS" ] || return 1
    sleep 1
  done
}
# fetch_all <label> <project dir> <output dir>: the five listings, each polled until it is filled
fetch_all() {
  local label="$1" dir="$2" out="$3"
  mkdir -p "$out"
  api POST plugin/await-activation "$dir" "$out/await.json" || true
  poll agent "$dir" "$out/agent.json" has-names "$out/agent.json" "$WANT/agents" || echo "    $label: /api/agent did not list every metaswarm agent within ${POLL_SECONDS}s"
  poll command "$dir" "$out/command.json" has-names "$out/command.json" "$WANT/commands" || echo "    $label: /api/command did not list every metaswarm command within ${POLL_SECONDS}s"
  poll skill "$dir" "$out/skill.json" has-names "$out/skill.json" "$WANT/skills" || echo "    $label: /api/skill did not list every metaswarm skill within ${POLL_SECONDS}s"
  api GET config "$dir" "$out/config.json" || true
  poll plugin "$dir" "$out/plugin.json" has-plugin "$out/plugin.json" || echo "    $label: /api/plugin did not report metaswarm-session active within ${POLL_SECONDS}s"
  if node_ok_for_mcp; then
    poll mcp "$dir" "$out/mcp.json" has-mcp "$out/mcp.json" || echo "    $label: /api/mcp did not report beads connected within ${POLL_SECONDS}s"
  fi
}
# check_all <label> <output dir> <checkout>: the assertions shared by every 2.x install
check_all() {
  local label="$1" out="$2"
  run_checks v2-config "$label" "$out/config.json" "$3/.opencode/OPENCODE.md"
  run_checks v2-agents "$label" "$out/agent.json" "$WANT/agents" "$EXPECT_AGENTS"
  run_checks v2-commands "$label" "$out/command.json" "$WANT/commands" "$EXPECT_COMMANDS" "$EXCLUDED"
  run_checks v2-skills "$label" "$out/skill.json" "$WANT/skills" "$EXPECT_SKILLS" "$OC"
  run_checks v2-plugin "$label" "$out/plugin.json" "$OC/plugins/metaswarm-session.js"
  if node_ok_for_mcp; then
    run_checks v2-mcp "$label" "$out/mcp.json"
  else
    skip "$label /api/mcp: node $(node --version 2>/dev/null) is older than 22.18 and cannot run the BEADS MCP server (.ts)"
  fi
}
server_failed() { fail "$1: the server did not come up within ${START_TIMEOUT}s: $(tail -5 "$SRV_LOG" 2>/dev/null | tr '\n' ' ' | cut -c1-400)"; }

run_v2() {
  local bin="$1" G rc src bare role other model
  echo "OpenCode 2.x: $bin ($VERSION)"
  command -v curl >/dev/null 2>&1 || { fail "2.x: curl is needed to query the server"; return 0; }

  # -- the working tree installed with --from --
  use_home v2
  new_project "$TMP_BASE/v2/proj"
  install_from_tree "2.x"
  if serve_start "$bin" v2 "server password"; then
    pass "2.x: serve started"
    fetch_all "2.x" "$TMP_BASE/v2/proj" "$TMP_BASE/v2/out"
    check_all "2.x" "$TMP_BASE/v2/out" "$ROOT"
  else
    server_failed "2.x"
  fi
  serve_stop

  # -- case B: a project-level agent with a model overrides the global one --
  # Same HOME as above, another project. Written by the per-role generator, which
  # renders the whole agent plus `model`.
  echo "OpenCode 2.x, project-level agent with a model"
  role="coder"; other="planner"; model="someprovider/some-model"
  new_project "$TMP_BASE/v2b/proj"
  mkdir -p "$TMP_BASE/v2b/proj/.metaswarm"
  printf 'roles:\n  %s:\n    opencode: %s\n' "$role" "$model" > "$TMP_BASE/v2b/proj/.metaswarm/models.yaml"
  rc=0; (cd "$TMP_BASE/v2b/proj" && bash "$ROOT/bin/metaswarm-agents.sh" generate --host opencode > "$TMP_BASE/v2b/generate.out" 2>&1 </dev/null) || rc=$?
  if [ "$rc" = 0 ] && grep -q "^model: $model\$" "$TMP_BASE/v2b/proj/.opencode/agents/$role.md" 2>/dev/null && [ "$(ls "$TMP_BASE/v2b/proj/.opencode/agents" | grep -c .)" = 1 ]; then
    pass "2.x project agent: metaswarm-agents.sh generate --host opencode wrote only .opencode/agents/$role.md, with the model"
  else
    fail "2.x project agent: generate --host opencode (exit $rc): $(tail -3 "$TMP_BASE/v2b/generate.out" | tr '\n' ' ')"
  fi
  if serve_start "$bin" v2b "server password"; then
    pass "2.x project agent: serve started"
    mkdir -p "$TMP_BASE/v2b/out"
    api POST plugin/await-activation "$TMP_BASE/v2b/proj" "$TMP_BASE/v2b/out/await.json" || true
    poll agent "$TMP_BASE/v2b/proj" "$TMP_BASE/v2b/out/agent.json" has-names "$TMP_BASE/v2b/out/agent.json" "$WANT/agents" || echo "    2.x project agent: /api/agent did not list every metaswarm agent within ${POLL_SECONDS}s"
    poll agent "$TMP_BASE/v2b/proj" "$TMP_BASE/v2b/out/agent.json" has-model "$TMP_BASE/v2b/out/agent.json" "$role" || true
    run_checks v2-override "2.x project agent" "$TMP_BASE/v2b/out/agent.json" "$role" "$model" "$other" "$WANT/agents" "$EXPECT_AGENTS"
  else
    server_failed "2.x project agent"
  fi
  serve_stop

  # -- case A: installed by cloning, so the clone sits inside the directory OpenCode scans --
  echo "OpenCode 2.x, installed by cloning into the OpenCode directory"
  G="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c init.defaultBranch=main -c core.hooksPath=/dev/null"
  src="$TMP_BASE/v2a/src"; bare="$TMP_BASE/v2a/bare.git"
  mkdir -p "$src"
  # a copy of the working tree (a CI checkout is shallow, and this also covers uncommitted work)
  if (cd "$ROOT" && tar -cf - --exclude=./.git --exclude=./node_modules .) | (cd "$src" && tar -xf -) \
     && (cd "$src" && $G init -q && $G checkout -q -b distro && $G add -A && $G commit -q -m "working tree") > "$TMP_BASE/v2a/git.out" 2>&1 \
     && $G clone -q --bare "$src" "$bare" >> "$TMP_BASE/v2a/git.out" 2>&1; then
    pass "2.x clone: built a file:// repository from a copy of the working tree"
  else
    fail "2.x clone: could not build the repository: $(tail -3 "$TMP_BASE/v2a/git.out" 2>/dev/null | tr '\n' ' ')"
  fi
  use_home v2a
  new_project "$TMP_BASE/v2a/proj"
  rc=0; (cd "$TMP_BASE" && METASWARM_REPO_URL="file://$bare" METASWARM_REF=distro bash "$INSTALL" > "$H/install.out" 2>&1 </dev/null) || rc=$?
  if [ "$rc" = 0 ] && [ -d "$OC/metaswarm/.git" ] && [ "$(readlink "$OC/skills/start")" = "$OC/metaswarm/skills/start" ]; then
    pass "2.x clone: install.sh cloned into the OpenCode directory and linked into the clone"
  else
    fail "2.x clone: install.sh exited $rc: $(tail -3 "$H/install.out" | tr '\n' ' ')"
  fi
  if serve_start "$bin" v2a "server password"; then
    pass "2.x clone: serve started"
    fetch_all "2.x clone" "$TMP_BASE/v2a/proj" "$TMP_BASE/v2a/out"
    check_all "2.x clone" "$TMP_BASE/v2a/out" "$OC/metaswarm"
    # nothing in the clone's own agents/, skills/ or commands/ shows up under another name
    if [ -f "$TMP_BASE/v2/out/agent.json" ]; then
      run_checks v2-same "2.x clone" "$TMP_BASE/v2/out" "$TMP_BASE/v2a/out"
    else
      fail "2.x clone: no --from listing to compare with"
    fi
  else
    server_failed "2.x clone"
  fi
  serve_stop
}

# --- Run ---

[ "$(lines "$WANT/agents")" = "$EXPECT_AGENTS" ] && pass "the tree has $EXPECT_AGENTS agents" || fail "the tree has $(lines "$WANT/agents") agents, this test expects $EXPECT_AGENTS"
[ "$(lines "$WANT/commands")" = "$EXPECT_COMMANDS" ] && pass "the tree has $EXPECT_COMMANDS linked commands" || fail "the tree has $(lines "$WANT/commands") linked commands, this test expects $EXPECT_COMMANDS"
[ "$(lines "$WANT/skills")" = "$EXPECT_SKILLS" ] && pass "the tree has $EXPECT_SKILLS skills" || fail "the tree has $(lines "$WANT/skills") skills, this test expects $EXPECT_SKILLS"

RAN1=0
RAN2=0
VERSION=""
LINE=""
if [ -z "$BIN_A" ] && [ -z "$BIN_B" ]; then
  fail "METASWARM_LIVE_REQUIRED=1 but no OpenCode binary was found (set OPENCODE_BIN and OPENCODE2_BIN)"
fi
for bin in "$BIN_A" "$BIN_B"; do
  [ -n "$bin" ] || continue
  if ! command -v "$bin" >/dev/null 2>&1; then
    fail "not an executable: $bin"
    continue
  fi
  use_home probe
  version_of "$bin"
  case "$LINE" in
    1)
      if [ "$RAN1" = 1 ]; then skip "$bin ($VERSION): the 1.x half already ran"; else RAN1=1; run_v1 "$bin"; fi ;;
    2)
      if [ "$RAN2" = 1 ]; then skip "$bin ($VERSION): the 2.x half already ran"; else RAN2=1; run_v2 "$bin"; fi ;;
    *)
      if [ "$FROM_PATH" = 1 ] && [ "$REQUIRED" != 1 ]; then
        skip "$bin (found on PATH): cannot tell the OpenCode line from its --version output '${VERSION:-<none>}'; set OPENCODE_BIN to test a binary"
      else
        fail "$bin: cannot tell the OpenCode line from its --version output '${VERSION:-<none>}'"
      fi ;;
  esac
done
[ "$RAN1" = 1 ] || skip "the 1.x half did not run (no 1.x binary)"
[ "$RAN2" = 1 ] || skip "the 2.x half did not run (no 2.x binary)"
if [ "$REQUIRED" = 1 ]; then
  [ "$RAN1" = 1 ] && [ "$RAN2" = 1 ] && pass "METASWARM_LIVE_REQUIRED=1: both halves ran" || fail "METASWARM_LIVE_REQUIRED=1: both halves must run (1.x ran: $RAN1, 2.x ran: $RAN2)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
DONE=1
[ "$FAIL" -eq 0 ]
