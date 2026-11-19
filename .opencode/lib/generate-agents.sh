#!/usr/bin/env bash
# generate-agents.sh — render every metaswarm agent for a GLOBAL OpenCode install.
#
#   generate-agents.sh generate --dest <dir> [--force]
#   generate-agents.sh check    --dest <dir>
#   generate-agents.sh clean    --dest <dir> [--force]
#
# <dir> is the user's own OpenCode agents directory (~/.config/opencode/agents),
# shared with agents they wrote themselves. For each agents/*.md of this metaswarm
# checkout, generate writes <dir>/<name>.md with OpenCode frontmatter (description,
# mode: subagent, and permission/edit: deny for read-only agents; no model, so the
# agent inherits the session model) followed by the canonical body.
#
# Ownership: a file is metaswarm's only if it is a regular file (not a symlink) whose
# line right after the closing frontmatter --- is this tool's generated-by header.
# Everything else in <dir> belongs to the user and is never modified or reported,
# except that a user file sitting where an agent would go is named in a warning.
#
# The metaswarm root is this script's own checkout (<root>/.opencode/lib/), never
# PLUGIN_ROOT / CLAUDE_PLUGIN_ROOT from the environment. It needs no models.yaml and
# no git repository. The per-project, per-role variant with a model lives in
# bin/metaswarm-agents.sh (generate --host opencode).
#
# Bash 3.2 compatible (no associative arrays, no mapfile).

set -u

# CDPATH would make a relative cd print the directory it picked and land elsewhere.
unset CDPATH
GA_LIB="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 3
GA_ROOT="$(CDPATH= cd -- "$GA_LIB/../.." && pwd -P)" || exit 3
GA_MARK=' — global OpenCode agent; re-run the metaswarm OpenCode installer, do not edit -->'

# Helpers shared with the project-scope generator: sha, HEADER_RE, init_env (version).
if [ ! -f "$GA_ROOT/bin/metaswarm-agents.sh" ]; then
  echo "generate-agents.sh: not inside a metaswarm checkout: $GA_ROOT" >&2
  exit 3
fi
# shellcheck source=/dev/null
. "$GA_ROOT/bin/metaswarm-agents.sh"
# init_env honours MS_PLUGIN / PLUGIN_ROOT from the environment; pin both to this root.
unset MS_PLUGIN
PLUGIN_ROOT="$GA_ROOT" init_env
GA_VERSION="${MS_VERSION:-}"

GA_FAILED=0
GA_TMP=""   # the temp file in flight, removed on exit or interrupt
# An if, not "[ -z ] || rm": bash can skip the right-hand side of an || list when the
# trap fires between two stages of a pipeline, which would leave the temp file behind.
ga_cleanup() { if [ -n "$GA_TMP" ]; then rm -f -- "$GA_TMP"; fi; GA_TMP=""; }
warn() { echo "warning: $*" >&2; }
err() { echo "error: $*" >&2; GA_FAILED=1; }

usage() {
  cat >&2 <<'EOF'
usage: generate-agents.sh generate --dest <dir> [--force]
       generate-agents.sh check    --dest <dir>
       generate-agents.sh clean    --dest <dir> [--force]

  generate  write every metaswarm agent into <dir> and remove generated files whose
            agent no longer exists. Files that are not metaswarm's (user-authored,
            symlinks, directories) are skipped with a warning. A generated file that
            was edited by hand is kept with a warning; --force OVERWRITES it (or
            DELETES it, if its agent is gone) and the edits are lost. If more than
            half of the generated files would be removed as orphans, none is removed
            (the checkout looks incomplete) unless --force is given.
  check     report missing, stale, hand-edited and orphan generated files; exit 1 if
            there are any. A user-authored file with an agent's name is reported as
            skipped and does not fail the check.
  clean     remove the generated files. One that was edited by hand is kept with a
            warning; --force DELETES it too. User-authored files are never removed.
EOF
  exit 64
}

# --- Classification ---

# header_of <file>: the line right after the closing frontmatter ---, if the file
# starts with a frontmatter block. Reads no further than that line.
header_of() {
  awk 'NR == 1 { if ($0 != "---") exit; next }
       $0 == "---" { if ((getline l) > 0) print l; exit }' < "$1" 2>/dev/null
}

# is_ours <path>: regular file, not a symlink, global-scope header in the right place
is_ours() {
  local h
  [ ! -L "$1" ] && [ -f "$1" ] || return 1
  h="$(header_of "$1")"
  printf '%s\n' "$h" | grep -q "$HEADER_RE" || return 1
  # The whole line must be: version, a 64-digit hash, then the marker and nothing else.
  case "$h" in *"$GA_MARK") h="${h%"$GA_MARK"}" ;; *) return 1 ;; esac
  printf '%s\n' "$h" | grep -Eq '^<!-- generated-by: metaswarm v[^ ]+ sha256:[0-9a-f]{64}$'
}

# Same hash scheme as bin/metaswarm-agents.sh: sha256 of the file without its header
# line. Only called on files that passed is_ours, so the header position is known.
without_header() {
  awk 'NR > 1 && !d && $0 == "---" { print; d = 1; getline; next } { print }' < "$1"
}
edited_by_hand() {
  local want
  want="$(header_of "$1" | sed -n 's/^<!-- generated-by: metaswarm v[^ ]* sha256:\([0-9a-f]*\) .*/\1/p')"
  [ "$(without_header "$1" | sha)" != "$want" ]
}

# --- Rendering ---

# render_plain <canonical file>: frontmatter + body, without the header line
render_plain() {
  local src="$1" desc
  desc="$(awk '/^---$/ { if (++dashes == 2) exit; next } /^description:/ { print; exit }' < "$src")"
  [ -n "$desc" ] || { echo "no description in frontmatter: $src" >&2; return 1; }
  echo "---"
  printf '%s\n' "$desc"
  echo "mode: subagent"
  if awk '/^---$/ { if (++dashes == 2) exit; next } /^disallowedTools:/ { found = 1 } END { exit !found }' < "$src"; then
    printf 'permission:\n  edit: deny\n'
  fi
  echo "---"
  # body = everything after the closing ---
  awk 'c >= 2 { print } /^---$/ { c++ }' < "$src"
}

# render_global <canonical file>: write the generated file to stdout.
# Returns non-zero if any stage fails; no intermediate file is used.
render_global() {
  local src="$1" hash st
  hash="$(render_plain "$src" | sha; exit "${PIPESTATUS[0]}")" || return 1
  printf '%s\n' "$hash" | grep -Eq '^[0-9a-f]{64}$' || { echo "cannot hash the render of $src" >&2; return 1; }
  render_plain "$src" | awk -v h="<!-- generated-by: metaswarm v$GA_VERSION sha256:$hash$GA_MARK" \
    '{ print } /^---$/ { c++; if (c == 2) print h }'
  st="${PIPESTATUS[0]}${PIPESTATUS[1]}"
  [ "$st" = "00" ]
}

# render_to <canonical file> <out file>: render and verify what actually landed on
# disk (a full disk can truncate the file without any command failing): the result
# must carry this tool's header in the right place and match its own hash.
render_to() {
  render_global "$1" > "$2" 2>/dev/null || return 1
  [ -s "$2" ] && is_ours "$2" && ! edited_by_hand "$2"
}

# file_mode: the mode a newly created file gets under the current umask
file_mode() { printf '%o\n' $(( 0666 & ~0$(umask) )); }

# canonical_agents: one agents/*.md path per line; fails if there are none
canonical_agents() {
  local f n=0
  for f in "$GA_ROOT"/agents/*.md; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"; n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}

# --- Subcommands ---

cmd_generate() {
  local dest="$1" force="$2" src name t f mode ours=0 orphans=0
  canonical_agents >/dev/null || { err "no agents found in $GA_ROOT/agents; nothing written or removed"; return 1; }
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    [ -d "$dest" ] || { err "destination is not a directory: $dest"; return 1; }
  else
    mkdir -p "$dest" 2>/dev/null || { err "cannot create destination directory: $dest"; return 1; }
  fi
  mode="$(file_mode)"
  for src in "$GA_ROOT"/agents/*.md; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    t="$dest/$name"
    if [ -L "$t" ] || { [ -e "$t" ] && [ ! -f "$t" ]; }; then
      warn "skipped (not a regular file, left untouched): $t"; continue
    fi
    if [ -f "$t" ]; then
      if ! is_ours "$t"; then
        warn "skipped (user-authored, left untouched): $t"; continue
      elif [ "$force" -eq 0 ] && edited_by_hand "$t"; then
        warn "skipped (hand-edited; --force will OVERWRITE it and discard the edits): $t"; continue
      fi
    fi
    # Render beside the target so the final mv is a rename: it replaces the name and
    # can never write through a link. The temp name is a dotfile without .md, so
    # OpenCode never loads it as an agent.
    GA_TMP="$(mktemp "$dest/.metaswarm-agent.XXXXXX" 2>/dev/null)" || { GA_TMP=""; err "cannot write in $dest (failed: $t)"; continue; }
    if ! render_to "$src" "$GA_TMP"; then
      ga_cleanup; err "cannot write $t (render failed or incomplete; nothing installed for it)"; continue
    fi
    if [ -f "$t" ] && cmp -s "$GA_TMP" "$t"; then
      ga_cleanup; echo "unchanged $t"; continue
    fi
    if chmod "$mode" "$GA_TMP" 2>/dev/null && mv -f "$GA_TMP" "$t" 2>/dev/null; then
      GA_TMP=""; echo "wrote $t"
    else
      ga_cleanup; err "cannot write $t"
    fi
  done
  # Orphans: generated files whose agent is gone
  for f in "$dest"/*.md; do
    is_ours "$f" || continue
    ours=$((ours + 1))
    [ -f "$GA_ROOT/agents/$(basename "$f")" ] || orphans=$((orphans + 1))
  done
  if [ "$force" -eq 0 ] && [ $((orphans * 2)) -gt "$ours" ]; then
    warn "kept $orphans of $ours generated files in $dest whose agent is missing from $GA_ROOT/agents: this looks like an incomplete metaswarm checkout. Nothing was removed; --force will DELETE them."
    [ "$GA_FAILED" -eq 0 ]; return
  fi
  for f in "$dest"/*.md; do
    is_ours "$f" || continue
    [ -f "$GA_ROOT/agents/$(basename "$f")" ] && continue
    if [ "$force" -eq 0 ] && edited_by_hand "$f"; then
      warn "kept orphan (hand-edited; its agent no longer exists, --force will DELETE it): $f"; continue
    fi
    if rm -f -- "$f" 2>/dev/null; then echo "removed orphan $f"; else err "cannot remove orphan $f"; fi
  done
  [ "$GA_FAILED" -eq 0 ]
}

cmd_check() {
  local dest="$1" src t f drift=0
  canonical_agents >/dev/null || { err "no agents found in $GA_ROOT/agents"; return 1; }
  for src in "$GA_ROOT"/agents/*.md; do
    [ -f "$src" ] || continue
    t="$dest/$(basename "$src")"
    if [ -L "$t" ] || { [ -e "$t" ] && [ ! -f "$t" ]; }; then
      echo "skipped (not a regular file): $t"
    elif [ ! -e "$t" ]; then
      echo "missing: $t"; drift=1
    elif ! is_ours "$t"; then
      echo "skipped (user-authored): $t"
    elif edited_by_hand "$t"; then
      echo "hand-edited: $t"; drift=1
    else
      GA_TMP="$(mktemp)" || { GA_TMP=""; err "cannot create a temporary file"; return 1; }
      if ! render_to "$src" "$GA_TMP"; then ga_cleanup; err "cannot render $src; nothing could be compared"; return 1; fi
      cmp -s "$GA_TMP" "$t" || { echo "stale: $t"; drift=1; }
      ga_cleanup
    fi
  done
  for f in "$dest"/*.md; do
    is_ours "$f" || continue
    [ -f "$GA_ROOT/agents/$(basename "$f")" ] && continue
    if edited_by_hand "$f"; then echo "orphan (hand-edited): $f"; else echo "orphan: $f"; fi
    drift=1
  done
  [ "$drift" -eq 0 ] || return 1
  echo "global OpenCode agents are up to date"
}

cmd_clean() {
  local dest="$1" force="$2" f
  for f in "$dest"/*.md; do
    is_ours "$f" || continue
    if [ "$force" -eq 0 ] && edited_by_hand "$f"; then
      warn "kept (hand-edited; --force will DELETE it): $f"; continue
    fi
    if rm -f -- "$f" 2>/dev/null; then echo "removed $f"; else err "cannot remove $f"; fi
  done
  [ "$GA_FAILED" -eq 0 ]
}

main() {
  local cmd="${1:-}" arg dest="" has_dest=0 force=0
  case "$cmd" in generate|check|clean) shift ;; *) usage ;; esac
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --dest) [ $# -gt 0 ] && [ "$has_dest" -eq 0 ] && [ -n "$1" ] || usage; dest="$1"; has_dest=1; shift ;;
      --force) [ "$cmd" != check ] || usage; force=1 ;;
      *) usage ;;
    esac
  done
  [ "$has_dest" -eq 1 ] || usage
  case "$dest" in /) ;; */) dest="${dest%/}" ;; esac
  # A relative path such as a=b or -x must never be read as an assignment or an option.
  case "$dest" in /*|./*|../*) ;; *) dest="./$dest" ;; esac
  if [ -z "$GA_VERSION" ]; then
    echo "error: cannot read the metaswarm version from $GA_ROOT/.claude-plugin/plugin.json; nothing was changed" >&2
    exit 3
  fi
  trap 'ga_cleanup' EXIT
  trap 'ga_cleanup; trap - EXIT; exit 130' INT
  trap 'ga_cleanup; trap - EXIT; exit 143' TERM
  case "$cmd" in
    generate) cmd_generate "$dest" "$force" ;;
    check) cmd_check "$dest" ;;
    clean) cmd_clean "$dest" "$force" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
