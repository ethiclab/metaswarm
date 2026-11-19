#!/usr/bin/env bash
# tests/opencode/test-generate-agents.sh
# Tests for .opencode/lib/generate-agents.sh (generate / check / clean --dest <dir>):
# the global, all-agents OpenCode renderer and its ownership rules for a destination
# directory that is shared with the user's own agents.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOL_REL=".opencode/lib/generate-agents.sh"
VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/.claude-plugin/plugin.json" | head -1)"
MARK=' — global OpenCode agent; re-run the metaswarm OpenCode installer, do not edit -->'
PROJECT_HDR="<!-- generated-by: metaswarm v$VERSION sha256:0000000000000000000000000000000000000000000000000000000000000000 — edit .metaswarm/models.yaml, not this file -->"
PASS=0
FAIL=0
TMP_BASE="$(mktemp -d)"
# bash 3.2 exits with the EXIT trap's status (0) when `set -u` aborts the script,
# so a crash would look like a pass. DONE is set only after the summary runs.
DONE=0
trap 'chmod -R u+rwx "${TMP_BASE:?}" 2>/dev/null; rm -rf "${TMP_BASE:?}"; [ "$DONE" = 1 ] || { echo "ABORTED before summary" >&2; exit 1; }' EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
check() { if [ "$2" = "0" ]; then pass "$1"; else fail "$1"; fi; }

# Everything runs from a directory outside any git repo, with no models.yaml.
CWD="$TMP_BASE/cwd"
mkdir -p "$CWD"
R="$ROOT"   # the root whose generator is run; swapped for a copy by new_root

N=0
new_dest() { N=$((N + 1)); D="$TMP_BASE/d$N/agents"; }

# new_root: copy the parts of ROOT the generator needs; sets R
new_root() {
  N=$((N + 1))
  R="$TMP_BASE/r$N"
  mkdir -p "$R/.opencode" "$R/.claude-plugin"
  cp -R "$ROOT/agents" "$R/agents"
  cp -R "$ROOT/bin" "$R/bin"
  cp -R "$ROOT/.opencode/lib" "$R/.opencode/lib"
  cp "$ROOT/.claude-plugin/plugin.json" "$R/.claude-plugin/plugin.json"
}

# run <args...>: runs $R's generator from $CWD; sets OUT and RC
run() {
  RC=0
  OUT="$(cd "$CWD" && env -u PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT -u extensionPath -u MS_PLUGIN bash "$R/$TOOL_REL" "$@" 2>&1)" || RC=$?
}

has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }
names() { ls "$1" 2>/dev/null | sort; }
canon_names() { (cd "$R/agents" && ls *.md) | sort; }
dir_sum() { [ -d "$1" ] || return 0; (cd "$1" && for f in *; do [ -f "$f" ] && { printf '%s ' "$f"; sha < "$f"; }; done); }
# fm <file>: frontmatter lines (between the first two ---)
fm() { awk '/^---$/ { if (++c == 2) exit; next } c == 1 { print }' "$1"; }
# after_fm <file>: the line right after the closing ---
after_fm() { awk 'p { print; exit } /^---$/ { if (++c == 2) p = 1 }' "$1"; }
# gen_body <file>: everything after the header line
gen_body() { awk 'p > 1 { print } p == 1 { p = 2 } /^---$/ && !p { if (++c == 2) p = 1 }' "$1"; }
canon_body() { awk 'c >= 2 { print } /^---$/ { c++ }' "$1"; }
is_readonly() { fm "$1" | grep -q '^disallowedTools:'; }
write_user() { printf -- '---\ndescription: mine\nmode: primary\n---\n\n# My own agent\n' > "$1"; }

FIRST="$(cd "$ROOT/agents" && ls *.md | sort | sed -n '1p')"    # an agent used for collisions
SECOND="$(cd "$ROOT/agents" && ls *.md | sort | sed -n '2p')"   # one that must still be written

echo "Running .opencode/lib/generate-agents.sh tests..."

echo "Test 1: generate writes every canonical agent"
new_dest
run generate --dest "$D"
check "generate exits 0 (out: $(printf '%s' "$OUT" | tail -1))" "$RC"
[ -n "$(canon_names)" ] && [ "$(names "$D")" = "$(canon_names)" ] && pass "basenames equal agents/*.md" || fail "basenames equal agents/*.md"
[ -x "$ROOT/$TOOL_REL" ] && pass "generator is executable" || fail "generator is executable"
has "wrote $D/$FIRST" && pass "reports written files" || fail "reports written files"

echo "Test 2: OpenCode frontmatter, no Claude-only keys"
bad_keys=0; no_mode=0; bad_desc=0
for src in "$ROOT"/agents/*.md; do
  f="$D/$(basename "$src")"
  [ -f "$f" ] || { bad_keys=1; no_mode=1; bad_desc=1; continue; }
  fm "$f" | grep -Eq '^(name|model|disallowedTools):' && bad_keys=1
  grep -q 'disallowedTools' <<EOF && bad_keys=1
$(fm "$f")
EOF
  [ "$(fm "$f" | grep -c '^mode: subagent$')" = "1" ] || no_mode=1
  want="$(fm "$src" | grep '^description:' | head -1)"
  [ -n "$want" ] && [ "$(fm "$f" | grep '^description:')" = "$want" ] || bad_desc=1
done
check "no name:/model:/disallowedTools in any emitted frontmatter" "$bad_keys"
check "every file has mode: subagent" "$no_mode"
check "every file carries the canonical description verbatim" "$bad_desc"

echo "Test 3: permission block only for read-only agents"
perm_bad=0; ro=0; rw=0
for src in "$ROOT"/agents/*.md; do
  f="$D/$(basename "$src")"
  [ -f "$f" ] || { perm_bad=1; continue; }
  if is_readonly "$src"; then
    ro=$((ro + 1))
    fm "$f" | awk 'prev == "permission:" && $0 == "  edit: deny" { ok = 1 } { prev = $0 } END { exit !ok }' || perm_bad=1
  else
    rw=$((rw + 1))
    fm "$f" | grep -Eq '^permission:|edit: deny' && perm_bad=1
  fi
done
check "permission/edit: deny iff canonical has disallowedTools" "$perm_bad"
[ "$ro" -gt 0 ] && [ "$rw" -gt 0 ] && pass "both kinds exercised ($ro read-only, $rw writable)" || fail "both kinds exercised ($ro read-only, $rw writable)"

echo "Test 4: header, hash, body, check"
hdr_bad=0; hash_bad=0; body_bad=0
for src in "$ROOT"/agents/*.md; do
  f="$D/$(basename "$src")"
  [ -f "$f" ] || { hdr_bad=1; hash_bad=1; body_bad=1; continue; }
  hdr="$(after_fm "$f")"
  case "$hdr" in "<!-- generated-by: metaswarm v$VERSION sha256:"*"$MARK") ;; *) hdr_bad=1 ;; esac
  [ "$(grep -c '^<!-- generated-by: metaswarm ' "$f")" = "1" ] || hdr_bad=1
  want="$(awk '!d && /^<!-- generated-by: metaswarm /{d=1;next}1' "$f" | sha)"
  case "$hdr" in *"sha256:$want "*) ;; *) hash_bad=1 ;; esac
  [ "$(gen_body "$f")" = "$(canon_body "$src")" ] || body_bad=1
done
check "global-scope header is the line right after the closing ---" "$hdr_bad"
check "header hash covers the rest of the file (upstream scheme)" "$hash_bad"
check "body equals the canonical body" "$body_bad"
run check --dest "$D"
[ "$RC" = "0" ] && has "up to date" && pass "check is clean after generate" || fail "check is clean after generate: rc=$RC $OUT"

echo "Test 5: idempotent"
before="$(dir_sum "$D")"
run generate --dest "$D"
[ "$RC" = "0" ] && [ -n "$before" ] && [ "$(dir_sum "$D")" = "$before" ] && pass "second run leaves byte-identical files" || fail "second run leaves byte-identical files: rc=$RC"
[ "$(names "$D")" = "$(canon_names)" ] && pass "second run leaves no stray files" || fail "second run leaves no stray files: $(names "$D" | grep -v '\.md$' | tr '\n' ' ')"

echo "Test 6: renders from its own root, not the environment"
BOGUS="$TMP_BASE/bogus"
mkdir -p "$BOGUS/agents" "$BOGUS/.claude-plugin" "$BOGUS/bin"
printf -- '---\nname: bogus\ndescription: bogus\n---\n\n# Bogus\n' > "$BOGUS/agents/bogus.md"
printf '{ "version": "9.9.9" }\n' > "$BOGUS/.claude-plugin/plugin.json"
printf 'echo "sourced the bogus helper"; exit 7\n' > "$BOGUS/bin/metaswarm-agents.sh"
new_dest
RC=0
OUT="$(cd "$CWD" && PLUGIN_ROOT="$BOGUS" CLAUDE_PLUGIN_ROOT="$BOGUS" extensionPath="$BOGUS" MS_PLUGIN="$BOGUS" bash "$ROOT/$TOOL_REL" generate --dest "$D" 2>&1)" || RC=$?
check "generate exits 0 with bogus PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT" "$RC"
[ "$(names "$D")" = "$(canon_names)" ] && [ ! -e "$D/bogus.md" ] && pass "roster comes from the script's own root" || fail "roster comes from the script's own root"
[ -f "$D/$FIRST" ] && [ "$(dir_sum "$D")" = "$before" ] && pass "output identical to a clean-environment run" || fail "output identical to a clean-environment run"
(cd "$CWD" && git rev-parse --show-toplevel >/dev/null 2>&1) && fail "test cwd is unexpectedly inside a git repo" || pass "ran with cwd outside any git repo"
[ ! -e "$CWD/.metaswarm" ] && [ ! -e "$CWD/.opencode" ] && [ ! -e "$CWD/.claude" ] && pass "nothing created in the cwd" || fail "nothing created in the cwd"

echo "Test 7: same-name targets that are not ours are skipped"
# 7a user-authored file
new_dest; mkdir -p "$D"; write_user "$D/$FIRST"; u="$(sha < "$D/$FIRST")"
run generate --dest "$D"
[ "$RC" = "0" ] && pass "user file: rc 0" || fail "user file: rc=$RC $OUT"
[ "$(sha < "$D/$FIRST")" = "$u" ] && pass "user file: untouched" || fail "user file: untouched"
printf '%s' "$OUT" | grep -F -- "$D/$FIRST" | grep -qi 'skip' && pass "user file: warning names the path" || fail "user file: warning names the path: $OUT"
has "wrote $D/$FIRST" && fail "user file: no 'wrote' line" || pass "user file: no 'wrote' line"
[ -f "$D/$SECOND" ] && [ "$(names "$D")" = "$(canon_names)" ] && pass "user file: other agents still written" || fail "user file: other agents still written"
run check --dest "$D"
[ "$RC" = "0" ] && has "skipped (user-authored)" && has "$D/$FIRST" && pass "check: user-authored collision reported, rc 0" || fail "check: user-authored collision: rc=$RC $OUT"
# 7b directory
new_dest; mkdir -p "$D/$FIRST"; echo keep > "$D/$FIRST/inner.txt"
run generate --dest "$D"
[ "$RC" = "0" ] && [ -d "$D/$FIRST" ] && [ "$(cat "$D/$FIRST/inner.txt")" = "keep" ] && [ "$(ls "$D/$FIRST")" = "inner.txt" ] && pass "directory: untouched, rc 0" || fail "directory: rc=$RC $OUT"
printf '%s' "$OUT" | grep -F -- "$D/$FIRST" | grep -qi 'skip' && [ -f "$D/$SECOND" ] && pass "directory: warned, others written" || fail "directory: warned, others written: $OUT"
# 7c symlink to a user file
new_dest; mkdir -p "$D"; write_user "$TMP_BASE/d$N/target.md"; u="$(sha < "$TMP_BASE/d$N/target.md")"
ln -s "$TMP_BASE/d$N/target.md" "$D/$FIRST"
run generate --dest "$D"
[ "$RC" = "0" ] && [ -L "$D/$FIRST" ] && [ "$(sha < "$TMP_BASE/d$N/target.md")" = "$u" ] && pass "symlink: still a symlink, target untouched, rc 0" || fail "symlink: rc=$RC $OUT"
printf '%s' "$OUT" | grep -F -- "$D/$FIRST" | grep -qi 'skip' && [ -f "$D/$SECOND" ] && pass "symlink: warned, others written" || fail "symlink: warned, others written: $OUT"
# 7c' symlink to one of OUR generated files elsewhere is still not ours
new_dest; mkdir -p "$D"
run generate --dest "$TMP_BASE/d$N/other"
ln -s "$TMP_BASE/d$N/other/$FIRST" "$D/$FIRST"; u="$(sha < "$TMP_BASE/d$N/other/$FIRST")"
printf '\nedited\n' >> "$TMP_BASE/d$N/other/$SECOND"
run generate --dest "$D" --force
[ "$RC" = "0" ] && [ -L "$D/$FIRST" ] && [ "$(sha < "$TMP_BASE/d$N/other/$FIRST")" = "$u" ] && pass "symlink to a generated file: left alone even with --force" || fail "symlink to a generated file: rc=$RC $OUT"
run clean --dest "$D" --force
[ -L "$D/$FIRST" ] && [ -f "$TMP_BASE/d$N/other/$FIRST" ] && pass "symlink to a generated file: clean --force keeps it" || fail "symlink to a generated file: clean --force keeps it"
# 7d dangling symlink
new_dest; mkdir -p "$D"; ln -s "$TMP_BASE/d$N/nowhere.md" "$D/$FIRST"
run generate --dest "$D"
[ "$RC" = "0" ] && [ -L "$D/$FIRST" ] && [ ! -e "$D/$FIRST" ] && [ ! -e "$TMP_BASE/d$N/nowhere.md" ] && pass "dangling symlink: still dangling, rc 0" || fail "dangling symlink: rc=$RC $OUT"
printf '%s' "$OUT" | grep -F -- "$D/$FIRST" | grep -qi 'skip' && [ -f "$D/$SECOND" ] && pass "dangling symlink: warned, others written" || fail "dangling symlink: warned, others written: $OUT"
run check --dest "$D"
[ "$RC" = "0" ] && pass "check: a non-regular collision does not fail check" || fail "check: non-regular collision: rc=$RC $OUT"

echo "Test 8: user files that only look generated are never touched"
new_dest; mkdir -p "$D"
run generate --dest "$D"
GLOBAL_HDR="$(after_fm "$D/$FIRST")"
# a) quotes the global header in its body, not right after the frontmatter
printf -- '---\ndescription: notes\nmode: subagent\n---\n\n# My notes\n\n%s\n' "$GLOBAL_HDR" > "$D/my-notes.md"
# b) project-scope header right after its frontmatter
printf -- '---\ndescription: project\nmode: subagent\n---\n%s\n\n# Project agent\n' "$PROJECT_HDR" > "$D/my-project-agent.md"
# c) no frontmatter at all, global header as the first line
printf '%s\n\n# No frontmatter\n' "$GLOBAL_HDR" > "$D/my-plain.md"
# d) not markdown
printf 'x\n' > "$D/notes.txt"
ua="$(sha < "$D/my-notes.md")"; ub="$(sha < "$D/my-project-agent.md")"; uc="$(sha < "$D/my-plain.md")"
user_intact() { [ "$(sha < "$D/my-notes.md")" = "$ua" ] && [ "$(sha < "$D/my-project-agent.md")" = "$ub" ] && [ "$(sha < "$D/my-plain.md")" = "$uc" ] && [ -f "$D/notes.txt" ]; }
user_unmentioned() { ! has "my-notes.md" && ! has "my-project-agent.md" && ! has "my-plain.md" && ! has "notes.txt"; }
run generate --dest "$D" --force
[ "$RC" = "0" ] && user_intact && user_unmentioned && pass "generate --force leaves them alone and silent" || fail "generate --force: rc=$RC $OUT"
run check --dest "$D"
[ "$RC" = "0" ] && user_intact && user_unmentioned && pass "check does not report them" || fail "check: rc=$RC $OUT"
run clean --dest "$D" --force
[ "$RC" = "0" ] && user_intact && user_unmentioned && pass "clean --force leaves them alone" || fail "clean --force: rc=$RC $OUT"
[ "$(names "$D" | tr '\n' ' ')" = "my-notes.md my-plain.md my-project-agent.md notes.txt " ] && pass "only the user's files remain after clean" || fail "only the user's files remain after clean: $(names "$D" | tr '\n' ' ')"

echo "Test 9: hand-edited generated file"
new_dest
run generate --dest "$D"
printf '\nmy local tweak\n' >> "$D/$FIRST"; u="$(sha < "$D/$FIRST")"
run generate --dest "$D"
[ "$RC" = "0" ] && [ "$(sha < "$D/$FIRST")" = "$u" ] && pass "kept without --force, rc 0" || fail "kept without --force: rc=$RC"
printf '%s' "$OUT" | grep -F -- "$D/$FIRST" | grep -q 'hand-edited' && pass "warning names the hand-edited path" || fail "warning names the hand-edited path: $OUT"
run check --dest "$D"
[ "$RC" = "1" ] && has "hand-edited: $D/$FIRST" && pass "check reports hand-edited, rc 1" || fail "check hand-edited: rc=$RC $OUT"
run generate --dest "$D" --force
[ "$RC" = "0" ] && ! grep -q 'my local tweak' "$D/$FIRST" && has "wrote $D/$FIRST" && pass "--force rewrites it" || fail "--force rewrites it: rc=$RC $OUT"
run check --dest "$D"
check "check clean after --force" "$RC"
# an edit that moves the header off its line makes the file the user's
awk '{ print } /^---$/ && ++c == 2 { print "" }' "$D/$FIRST" > "$D/$FIRST.tmp" && mv "$D/$FIRST.tmp" "$D/$FIRST"; u="$(sha < "$D/$FIRST")"
run generate --dest "$D" --force
[ "$RC" = "0" ] && [ "$(sha < "$D/$FIRST")" = "$u" ] && pass "header no longer right after the frontmatter: treated as user-authored" || fail "moved header: rc=$RC $OUT"

echo "Test 10: stale, missing and orphan files"
new_root; new_dest
run generate --dest "$D"
check "generate from a copied root exits 0" "$RC"
printf '\nA new canonical paragraph.\n' >> "$R/agents/$SECOND"
rm -f "$D/$FIRST"
run check --dest "$D"
[ "$RC" = "1" ] && has "stale: $D/$SECOND" && has "missing: $D/$FIRST" && pass "check reports stale and missing, rc 1" || fail "check stale/missing: rc=$RC $OUT"
run generate --dest "$D"
[ "$RC" = "0" ] && grep -q 'A new canonical paragraph.' "$D/$SECOND" && [ -f "$D/$FIRST" ] && pass "generate refreshes stale and missing" || fail "generate refreshes stale and missing: rc=$RC"
# orphan: the canonical agent goes away
rm -f "$R/agents/$FIRST"
run check --dest "$D"
[ "$RC" = "1" ] && has "orphan: $D/$FIRST" && pass "check reports the orphan, rc 1" || fail "check orphan: rc=$RC $OUT"
write_user "$D/user-orphan-lookalike.md"
run generate --dest "$D"
[ "$RC" = "0" ] && [ ! -e "$D/$FIRST" ] && has "removed orphan $D/$FIRST" && pass "generate removes the orphan" || fail "generate removes the orphan: rc=$RC $OUT"
[ -f "$D/user-orphan-lookalike.md" ] && [ -f "$D/$SECOND" ] && pass "orphan sweep leaves user files and live agents" || fail "orphan sweep leaves user files and live agents"
# hand-edited orphan
printf '\nmy tweak\n' >> "$D/$SECOND"; u="$(sha < "$D/$SECOND")"
rm -f "$R/agents/$SECOND"
run generate --dest "$D"
[ "$RC" = "0" ] && [ "$(sha < "$D/$SECOND")" = "$u" ] && pass "hand-edited orphan kept without --force" || fail "hand-edited orphan kept: rc=$RC $OUT"
printf '%s' "$OUT" | grep -F -- "$D/$SECOND" | grep -q 'hand-edited' && pass "hand-edited orphan warning names the path" || fail "hand-edited orphan warning: $OUT"
run generate --dest "$D" --force
[ "$RC" = "0" ] && [ ! -e "$D/$SECOND" ] && pass "hand-edited orphan removed with --force" || fail "hand-edited orphan removed with --force: rc=$RC $OUT"
# a root with no agents must not be read as "everything is an orphan"
kept="$(names "$D")"
rm -f "$R"/agents/*.md
run generate --dest "$D" --force
[ "$RC" != "0" ] && [ "$RC" != "64" ] && [ "$(names "$D")" = "$kept" ] && pass "empty agents/ is an error and removes nothing" || fail "empty agents/: rc=$RC $OUT"
R="$ROOT"

echo "Test 11: clean"
new_dest; mkdir -p "$D"; write_user "$D/my-agent.md"; u="$(sha < "$D/my-agent.md")"
run generate --dest "$D"
printf '\nmy tweak\n' >> "$D/$FIRST"; e="$(sha < "$D/$FIRST")"
run clean --dest "$D"
[ "$RC" = "0" ] && pass "clean exits 0" || fail "clean: rc=$RC $OUT"
[ "$(names "$D" | tr '\n' ' ')" = "$(printf '%s\n%s\n' "$FIRST" my-agent.md | sort | tr '\n' ' ')" ] && pass "clean removes ours, keeps the user file and the hand-edited one" || fail "clean leftovers: $(names "$D" | tr '\n' ' ')"
[ "$(sha < "$D/my-agent.md")" = "$u" ] && [ "$(sha < "$D/$FIRST")" = "$e" ] && pass "kept files are byte-identical" || fail "kept files are byte-identical"
printf '%s' "$OUT" | grep -F -- "$D/$FIRST" | grep -q 'hand-edited' && has "removed $D/$SECOND" && pass "clean warns about the hand-edited file, reports removals" || fail "clean output: $OUT"
run clean --dest "$D" --force
[ "$RC" = "0" ] && [ "$(names "$D")" = "my-agent.md" ] && [ "$(sha < "$D/my-agent.md")" = "$u" ] && pass "clean --force removes the hand-edited file, keeps the user file" || fail "clean --force: rc=$RC $(names "$D" | tr '\n' ' ')"
run clean --dest "$TMP_BASE/never-created"
[ "$RC" = "0" ] && [ ! -e "$TMP_BASE/never-created" ] && pass "clean on a missing dest is a no-op" || fail "clean on a missing dest: rc=$RC $OUT"
run check --dest "$TMP_BASE/never-created"
[ "$RC" = "1" ] && [ ! -e "$TMP_BASE/never-created" ] && pass "check on a missing dest reports drift without creating it" || fail "check on a missing dest: rc=$RC"

echo "Test 12: write failures"
new_dest; mkdir -p "$(dirname "$D")"; echo "i am a file" > "$D"
run generate --dest "$D"
[ "$RC" != "0" ] && [ "$RC" != "64" ] && pass "dest is a regular file: non-zero exit" || fail "dest is a regular file: rc=$RC $OUT"
has "wrote " && fail "dest is a regular file: no 'wrote' line" || pass "dest is a regular file: no 'wrote' line"
[ "$(cat "$D")" = "i am a file" ] && pass "dest is a regular file: file untouched" || fail "dest is a regular file: file untouched"
run generate --dest "$D/sub"
[ "$RC" != "0" ] && [ "$RC" != "64" ] && ! has "wrote " && pass "dest under a regular file: non-zero exit, no 'wrote' line" || fail "dest under a regular file: rc=$RC $OUT"
# the final mv fails: stub mv on PATH
new_dest; mkdir -p "$TMP_BASE/stub"
printf '#!/bin/sh\nexit 1\n' > "$TMP_BASE/stub/mv"; chmod +x "$TMP_BASE/stub/mv"
RC=0
OUT="$(cd "$CWD" && PATH="$TMP_BASE/stub:$PATH" bash "$ROOT/$TOOL_REL" generate --dest "$D" 2>&1)" || RC=$?
[ "$RC" != "0" ] && [ "$RC" != "64" ] && ! has "wrote " && pass "failed mv: non-zero exit, no 'wrote' line" || fail "failed mv: rc=$RC $OUT"
has "$D/$FIRST" && [ -z "$(ls -A "$D")" ] && pass "failed mv: failure names the path, no temp files left behind" || fail "failed mv: leftovers: $(ls -A "$D" | tr '\n' ' ')"
if [ "$(id -u)" = "0" ]; then
  echo "  SKIP: unwritable dest (running as root)"
else
  new_dest; mkdir -p "$D"; chmod a-w "$D"
  run generate --dest "$D"
  [ "$RC" != "0" ] && [ "$RC" != "64" ] && ! has "wrote " && [ -z "$(names "$D")" ] && pass "unwritable dest: non-zero exit, no 'wrote' line" || fail "unwritable dest: rc=$RC $OUT"
  chmod u+w "$D"
fi

echo "Test 13: usage errors"
new_dest
usage_case() { local d="$1"; shift; run "$@"; [ "$RC" = "64" ] && [ ! -e "$D" ] && pass "$d" || fail "$d: rc=$RC $OUT"; }
usage_case "no subcommand"
usage_case "unknown subcommand" frobnicate --dest "$D"
usage_case "generate without --dest" generate
usage_case "check without --dest" check
usage_case "clean without --dest" clean
usage_case "--dest without a value" generate --dest
usage_case "empty --dest value" generate --dest ""
usage_case "unknown argument" generate --dest "$D" --bogus
usage_case "stray positional argument" generate --dest "$D" extra
usage_case "--dest given twice" generate --dest "$D" --dest "$D"
usage_case "check --force" check --dest "$D" --force
run generate
has "usage:" && has "--dest" && pass "usage text is printed" || fail "usage text is printed: $OUT"

# --- Review round 1 ---

REAL_AWK="$(command -v awk)"
REAL_RM="$(command -v rm)"
STUBS="$TMP_BASE/stubs"
SCRATCH_TMP="$TMP_BASE/tmpdir"
# run_stub <stub dir> <args...>: like run, with <stub dir> first on PATH and an empty TMPDIR
run_stub() {
  local stub="$1"; shift
  RC=0
  rm -rf "${SCRATCH_TMP:?}"; mkdir -p "$SCRATCH_TMP"
  OUT="$(cd "$CWD" && TMPDIR="$SCRATCH_TMP" PATH="$stub:$PATH" bash "$R/$TOOL_REL" "$@" 2>&1 </dev/null)" || RC=$?
}
dotfiles() { ls -A "$1" | grep -v '\.md$' || true; }
no_temps() { [ -z "$(dotfiles "$1")" ] && [ -z "$(ls -A "$SCRATCH_TMP")" ]; }
# An awk that damages only the final render (the call that inserts the header).
mk_awk_stub() {  # <dir> <mode: truncate BYTES | fail BYTES | empty>
  mkdir -p "$1"
  {
    echo '#!/bin/sh'
    echo 'case "$*" in *"generated-by: metaswarm v"*) ;; *) exec '"$REAL_AWK"' "$@" ;; esac'
    case "$2" in
      truncate) echo "$REAL_AWK"' "$@" | head -c '"$3"'; exit 0' ;;
      fail) echo "$REAL_AWK"' "$@" | head -c '"$3"'; exit 1' ;;
      empty) echo 'cat >/dev/null; exit 0' ;;
    esac
  } > "$1/awk"
  chmod +x "$1/awk"
}

echo "Test 14: a short or failed write never installs a damaged agent"
new_root; new_dest
run generate --dest "$D"
check "setup: generate exits 0" "$RC"
printf '\nA new canonical paragraph.\n' >> "$R/agents/$SECOND"   # SECOND is now stale
good="$(sha < "$D/$SECOND")"
short_case() {  # <label> <stub dir>
  rm -f "${D:?}/${FIRST:?}"                                      # FIRST is missing
  run_stub "$2" generate --dest "$D"
  [ "$RC" != "0" ] && [ "$RC" != "64" ] && pass "$1: non-zero exit" || fail "$1: rc=$RC $(printf '%s' "$OUT" | head -3)"
  has "wrote " && fail "$1: no 'wrote' line" || pass "$1: no 'wrote' line"
  [ ! -e "$D/$FIRST" ] && pass "$1: no empty or truncated file at a missing target" || fail "$1: left $(wc -c < "$D/$FIRST") bytes at the missing target"
  [ "$(sha < "$D/$SECOND")" = "$good" ] && pass "$1: existing good file unchanged" || fail "$1: existing good file unchanged"
  printf '%s' "$OUT" | grep -F -- "$D/$FIRST" | grep -q '^error:' && pass "$1: error names the target" || fail "$1: error names the target: $(printf '%s' "$OUT" | head -3)"
  no_temps "$D" && pass "$1: no temp files left" || fail "$1: temp files left: $(dotfiles "$D" | tr '\n' ' ') $(ls -A "$SCRATCH_TMP" | tr '\n' ' ')"
}
mk_awk_stub "$STUBS/awk-empty" empty;          short_case "empty output" "$STUBS/awk-empty"
mk_awk_stub "$STUBS/awk-t100" truncate 100;    short_case "truncated inside the frontmatter" "$STUBS/awk-t100"
mk_awk_stub "$STUBS/awk-t2000" truncate 2000;  short_case "truncated inside the body" "$STUBS/awk-t2000"
mk_awk_stub "$STUBS/awk-f2000" fail 2000;      short_case "partial output then exit 1" "$STUBS/awk-f2000"
mkdir -p "$STUBS/sha"
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > "$STUBS/sha/shasum"; cp "$STUBS/sha/shasum" "$STUBS/sha/sha256sum"
chmod +x "$STUBS/sha/shasum" "$STUBS/sha/sha256sum"
short_case "hash tool fails" "$STUBS/sha"
run_stub "$STUBS/awk-t2000" check --dest "$D"
[ "$RC" != "0" ] && [ "$RC" != "64" ] && has "error:" && ! has "stale: $D/$SECOND" && pass "check: a failed render is an error, not 'stale'" || fail "check with a failing render: rc=$RC $(printf '%s' "$OUT" | head -3)"
run generate --dest "$D"
[ "$RC" = "0" ] && [ -f "$D/$FIRST" ] && grep -q 'A new canonical paragraph.' "$D/$SECOND" && pass "a later healthy run repairs everything" || fail "later healthy run: rc=$RC"
run check --dest "$D"
check "check clean after the healthy run" "$RC"
R="$ROOT"

echo "Test 15: destination paths awk could misparse"
REL="$TMP_BASE/rel"; mkdir -p "$REL"
rel() { RC=0; OUT="$(cd "$REL" && bash "$ROOT/$TOOL_REL" "$@" 2>&1 </dev/null)" || RC=$?; }
rel generate --dest a=b
[ "$RC" = "0" ] && [ "$(names "$REL/a=b")" = "$(canon_names)" ] && pass "relative dest 'a=b': generate writes the roster" || fail "relative dest 'a=b': rc=$RC"
rel generate --dest a=b
[ "$RC" = "0" ] && ! has "skipped" && ! has "wrote " && pass "relative dest 'a=b': second run recognises its own files" || fail "relative dest 'a=b' second run: rc=$RC $(printf '%s' "$OUT" | head -2)"
rel check --dest a=b
[ "$RC" = "0" ] && ! has "skipped" && has "up to date" && pass "relative dest 'a=b': check is clean" || fail "relative dest 'a=b' check: rc=$RC $(printf '%s' "$OUT" | head -2)"
rel clean --dest a=b
[ "$RC" = "0" ] && [ -z "$(ls -A "$REL/a=b")" ] && pass "relative dest 'a=b': clean removes them" || fail "relative dest 'a=b' clean: rc=$RC left $(ls -A "$REL/a=b" | wc -l)"
rel generate --dest -dash
[ "$RC" = "0" ] && [ "$(names "$REL/-dash")" = "$(canon_names)" ] && pass "relative dest starting with '-'" || fail "relative dest '-dash': rc=$RC $(printf '%s' "$OUT" | head -2)"
rel check --dest -dash
check "relative dest starting with '-': check is clean" "$RC"

echo "Test 16: temp files"
new_dest
run_stub "$STUBS/none" generate --dest "$D"
[ "$RC" = "0" ] && no_temps "$D" && pass "normal generate leaves no temp files in dest or TMPDIR" || fail "normal generate temp files: rc=$RC"
run_stub "$STUBS/none" check --dest "$D"
[ "$RC" = "0" ] && no_temps "$D" && pass "check leaves no temp files" || fail "check temp files: rc=$RC"
# the in-dest temp name is a dotfile that OpenCode cannot load as an agent
new_dest; mkdir -p "$STUBS/mvlog"
MVLOG="$STUBS/mvlog/log"
printf '#!/bin/sh\nfor a in "$@"; do last2="$last"; last="$a"; done\nprintf "%%s\\n" "$last2" >> "%s"\nexit 1\n' "$MVLOG" > "$STUBS/mvlog/mv"; chmod +x "$STUBS/mvlog/mv"
run_stub "$STUBS/mvlog" generate --dest "$D"
moved="$(sed -n '1p' "$MVLOG" 2>/dev/null || true)"
tmpname="$(basename "${moved:-none}")"
case "$tmpname" in *.md|none) fail "in-dest temp name is a dotfile not ending in .md: '$tmpname'" ;; .*) pass "in-dest temp name is a dotfile not ending in .md" ;; *) fail "in-dest temp name is a dotfile not ending in .md: '$tmpname'" ;; esac
[ "$(dirname "${moved:-none}")" = "$D" ] && pass "temp file is created inside dest (rename, not copy)" || fail "temp file is created inside dest: '$moved'"
[ "$RC" != "0" ] && [ -z "$(ls -A "$D")" ] && [ -z "$(ls -A "$SCRATCH_TMP")" ] && pass "failed run leaves no temp files" || fail "failed run leaves temp files: rc=$RC $(ls -A "$D" | tr '\n' ' ')"
# interrupted while a temp file exists
new_dest; mkdir -p "$STUBS/mvterm"
printf '#!/bin/sh\nkill -TERM "$PPID"\nexit 1\n' > "$STUBS/mvterm/mv"; chmod +x "$STUBS/mvterm/mv"
run_stub "$STUBS/mvterm" generate --dest "$D"
[ "$RC" = "143" ] && pass "SIGTERM: exits 143" || fail "SIGTERM: rc=$RC"
[ -z "$(ls -A "$D")" ] && [ -z "$(ls -A "$SCRATCH_TMP")" ] && pass "SIGTERM: temp file removed" || fail "SIGTERM: left $(ls -A "$D" | tr '\n' ' ')"

echo "Test 17: a root without a version"
new_root; new_dest
printf '{ "name": "metaswarm" }\n' > "$R/.claude-plugin/plugin.json"
run generate --dest "$D"
[ "$RC" = "3" ] && has "version" && [ ! -e "$D" ] && pass "generate: exit 3 with an error, nothing written" || fail "generate without a version: rc=$RC $(printf '%s' "$OUT" | head -2)"
run check --dest "$D"
[ "$RC" = "3" ] && pass "check: exit 3" || fail "check without a version: rc=$RC"
R="$ROOT"

echo "Test 18: CDPATH cannot redirect the root"
new_root; new_dest
mkdir -p "$TMP_BASE/cdpath/.opencode/lib"
RC=0
OUT="$(cd "$R" && CDPATH="$TMP_BASE/cdpath" bash .opencode/lib/generate-agents.sh generate --dest "$D" 2>&1 </dev/null)" || RC=$?
[ "$RC" = "0" ] && [ "$(names "$D")" = "$(canon_names)" ] && pass "relative invocation with a hostile CDPATH works" || fail "hostile CDPATH: rc=$RC $(printf '%s' "$OUT" | head -2)"
R="$ROOT"

echo "Test 19: an incomplete checkout does not sweep the install"
new_root; new_dest
run generate --dest "$D"
all="$(names "$D")"
for f in "$R"/agents/*.md; do [ "$(basename "$f")" = "$SECOND" ] || rm -f "$f"; done
printf '\nA new canonical paragraph.\n' >> "$R/agents/$SECOND"
run generate --dest "$D"
[ "$RC" = "0" ] && [ "$(names "$D")" = "$all" ] && ! has "removed orphan" && pass "mass orphan sweep refused, rc 0, nothing removed" || fail "mass orphan sweep: rc=$RC removed $(printf '%s' "$OUT" | grep -c 'removed orphan')"
printf '%s' "$OUT" | grep '^warning:' | grep -i 'incomplete' | grep -q -- '--force' && pass "warning explains the incomplete checkout and --force" || fail "sweep warning: $(printf '%s' "$OUT" | grep '^warning:' | head -2)"
grep -q 'A new canonical paragraph.' "$D/$SECOND" && has "wrote $D/$SECOND" && pass "current agents are still written" || fail "current agents are still written"
run check --dest "$D"
[ "$RC" = "1" ] && has "orphan: $D/$FIRST" && pass "check still reports the orphans" || fail "check after refused sweep: rc=$RC"
run generate --dest "$D" --force
[ "$RC" = "0" ] && [ "$(names "$D")" = "$SECOND" ] && pass "--force performs the sweep" || fail "--force sweep: rc=$RC left $(names "$D" | wc -l)"
R="$ROOT"

echo "Test 20: --force warnings say what will be lost"
new_root; new_dest
run generate --dest "$D"
printf '\nmy tweak\n' >> "$D/$FIRST"; printf '\nmy tweak\n' >> "$D/$SECOND"
rm -f "${R:?}/agents/${SECOND:?}"
run generate --dest "$D"
printf '%s' "$OUT" | grep -F -- "$D/$FIRST" | grep -- '--force' | grep -q 'OVERWRITE' && pass "hand-edited file: --force will OVERWRITE it" || fail "hand-edited warning: $(printf '%s' "$OUT" | grep -F -- "$D/$FIRST")"
printf '%s' "$OUT" | grep -F -- "$D/$SECOND" | grep -- '--force' | grep -q 'DELETE' && pass "hand-edited orphan: --force will DELETE it" || fail "hand-edited orphan warning: $(printf '%s' "$OUT" | grep -F -- "$D/$SECOND")"
run clean --dest "$D"
printf '%s' "$OUT" | grep -F -- "$D/$FIRST" | grep -- '--force' | grep -q 'DELETE' && pass "clean: --force will DELETE it" || fail "clean warning: $(printf '%s' "$OUT" | grep -F -- "$D/$FIRST")"
R="$ROOT"

echo "Test 21: a malformed global header is not ours"
new_dest; mkdir -p "$D"
H64="0000000000000000000000000000000000000000000000000000000000000000"
mal() { printf -- '---\ndescription: x\nmode: subagent\n---\n%s\n\n# Mine\n' "$2" > "$D/$1"; }
mal "$FIRST"         "<!-- generated-by: metaswarm v$VERSION sha256:NOT-A-HASH$MARK"
mal "x-nosha.md"     "<!-- generated-by: metaswarm v$VERSION$MARK"
mal "x-trailing.md"  "<!-- generated-by: metaswarm v$VERSION sha256:$H64$MARK trailing text"
mal "x-cr.md"        "<!-- generated-by: metaswarm v$VERSION sha256:$H64$MARK"$'\r'
mal "x-indent.md"    " <!-- generated-by: metaswarm v$VERSION sha256:$H64$MARK"
mal "x-short.md"     "<!-- generated-by: metaswarm v$VERSION sha256:ab$MARK"
mal "x-midtext.md"   "<!-- generated-by: metaswarm v$VERSION sha256:$H64 any text here$MARK"
mal_sum() { local n; for n in "$FIRST" x-nosha.md x-trailing.md x-cr.md x-indent.md x-short.md x-midtext.md; do if [ -f "$D/$n" ]; then sha < "$D/$n"; else echo "gone:$n"; fi; done; }
m="$(mal_sum)"
run generate --dest "$D" --force
[ "$RC" = "0" ] && [ "$(mal_sum)" = "$m" ] && pass "generate --force leaves malformed-header files alone" || fail "generate --force on malformed headers: rc=$RC"
printf '%s' "$OUT" | grep -F -- "$D/$FIRST" | grep -q 'user-authored' && pass "malformed header on an agent name is a user-authored collision" || fail "malformed header collision: $(printf '%s' "$OUT" | grep -F -- "$D/$FIRST")"
run clean --dest "$D" --force
[ "$RC" = "0" ] && [ "$(mal_sum)" = "$m" ] && pass "clean --force leaves malformed-header files alone" || fail "clean --force on malformed headers: rc=$RC"

echo "Test 22: a failing removal is an error"
new_root; new_dest
run generate --dest "$D"
rm -f "${R:?}/agents/${FIRST:?}"
mkdir -p "$STUBS/rm"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *.md) exit 1 ;; esac; done\nexec %s "$@"\n' "$REAL_RM" > "$STUBS/rm/rm"; chmod +x "$STUBS/rm/rm"
run_stub "$STUBS/rm" generate --dest "$D"
[ "$RC" != "0" ] && [ "$RC" != "64" ] && [ -f "$D/$FIRST" ] && ! has "removed orphan" && pass "orphan rm fails: non-zero exit, no 'removed' line" || fail "orphan rm fails: rc=$RC"
printf '%s' "$OUT" | grep '^error:' | grep -qF -- "$D/$FIRST" && pass "orphan rm fails: error names the path" || fail "orphan rm fails: $(printf '%s' "$OUT" | grep '^error:' | head -2)"
run_stub "$STUBS/rm" clean --dest "$D"
[ "$RC" != "0" ] && [ "$RC" != "64" ] && has "error:" && ! has "removed " && pass "clean rm fails: non-zero exit and an error" || fail "clean rm fails: rc=$RC"
R="$ROOT"

echo "Test 23: check on a root with no agents"
new_root; new_dest
run generate --dest "$D"
for f in "$R"/agents/*.md; do rm -f "$f"; done
run check --dest "$D"
[ "$RC" = "1" ] && has "error:" && ! has "orphan" && ! has "up to date" && pass "check: rc 1 with an error, no orphan report" || fail "check on empty root: rc=$RC $(printf '%s' "$OUT" | head -2)"
R="$ROOT"

echo "Test 24: file mode follows the umask"
mode_of() { ls -l "$1" | cut -c1-10; }
new_dest
RC=0; OUT="$(cd "$CWD" && umask 022 && bash "$ROOT/$TOOL_REL" generate --dest "$D" 2>&1)" || RC=$?
[ "$(mode_of "$D/$FIRST")" = "-rw-r--r--" ] && pass "umask 022 gives 644" || fail "umask 022: $(mode_of "$D/$FIRST")"
new_dest
RC=0; OUT="$(cd "$CWD" && umask 077 && bash "$ROOT/$TOOL_REL" generate --dest "$D" 2>&1)" || RC=$?
[ "$(mode_of "$D/$FIRST")" = "-rw-------" ] && pass "umask 077 gives 600" || fail "umask 077: $(mode_of "$D/$FIRST")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
DONE=1
[ "$FAIL" -eq 0 ] || exit 1
