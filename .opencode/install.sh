#!/usr/bin/env bash
# .opencode/install.sh
# Install metaswarm for OpenCode, once per machine.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ethiclab/metaswarm/opencode/.opencode/install.sh | bash
#   # or, from a checkout
#   bash .opencode/install.sh [--from <checkout>]
#   bash .opencode/install.sh --migrate-project <project-dir> [--from <checkout>]
#
# Re-run it to update. Nothing is copied: skills, commands and the session plugin are
# symlinks into one clone, agents are generated from it. See docs/README.opencode.md.
#
# Bash 3.2 compatible. The body lives in functions and runs from the last line, so a
# download cut short cannot run half a script.

# Where the clone comes from. Overridden by METASWARM_REPO_URL / METASWARM_REF.
DEFAULT_REPO_URL="https://github.com/ethiclab/metaswarm.git"
DEFAULT_REF="opencode"

set -u

FAILED=0
say() { echo "  $*"; }
warn() { echo "  Warning: $*" >&2; }
err() { echo "  Error: $*" >&2; FAILED=1; }
die() { echo "  Error: $*" >&2; exit 1; }

usage_text() {
  cat <<'EOF'
usage: install.sh [--from <checkout>]
       install.sh --migrate-project <project-dir> [--from <checkout>]
       install.sh --help

  (no option)  Clone metaswarm into <opencode dir>/metaswarm, or update that clone,
               then link its skills, commands and session plugin into the OpenCode
               directory, generate its agents and write opencode.json if there is
               none. Safe to re-run; files that are not metaswarm's are never
               replaced.
  --from <checkout>
               Use an existing metaswarm checkout instead of the clone. git is not
               run against it.
  --migrate-project <project-dir>
               Only move the files of the old per-project OpenCode layout into
               <project-dir>/.metaswarm/migrate-backup-<timestamp>/. Installs nothing.

  <opencode dir> is $OPENCODE_CONFIG_DIR, else $XDG_CONFIG_HOME/opencode, else
  ~/.config/opencode.

  METASWARM_REPO_URL  repository to clone (first install only)
  METASWARM_REF       branch or tag to install; pass it on every run, or the next
                      run goes back to the default
EOF
}
usage() { usage_text >&2; exit 64; }

# abs_dir <dir>: absolute logical path of an existing directory
abs_dir() { (CDPATH= cd -- "$1" 2>/dev/null && pwd); }
# phys_dir <dir>: the same with symlinks resolved
phys_dir() { (CDPATH= cd -- "$1" 2>/dev/null && pwd -P); }
# sq <text>: single-quoted for a POSIX shell
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# json_str <text>: a JSON string literal
json_str() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }

oc_dir() {
  local d
  if [ -n "${OPENCODE_CONFIG_DIR:-}" ]; then
    d="$OPENCODE_CONFIG_DIR"
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    d="$XDG_CONFIG_HOME/opencode"
  elif [ -n "${HOME:-}" ]; then
    d="$HOME/.config/opencode"
  else
    die "cannot find the OpenCode directory: set HOME or OPENCODE_CONFIG_DIR"
  fi
  case "$d" in /*) ;; *) d="$PWD/$d" ;; esac
  printf '%s\n' "${d%/}"
}

# is_checkout <dir>: has what the installer links and runs
is_checkout() {
  [ -d "$1/skills" ] && [ -d "$1/commands" ] && [ -d "$1/agents" ] && [ -f "$1/.opencode/lib/generate-agents.sh" ]
}

# --- Clone or update ---

# update_clone <clone> <url> <ref>: returns non-zero, with git's own message shown,
# when the clone could not be brought to <ref>. Removes nothing.
update_clone() {
  local clone="$1" url="$2" ref="$3" origin need
  command -v git >/dev/null 2>&1 || { err "git is required"; return 1; }
  if [ -e "$clone" ] || [ -L "$clone" ]; then
    if [ ! -e "$clone/.git" ] || ! git -C "$clone" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      err "$clone exists but is not a git clone of metaswarm. Move it away and run the installer again."
      return 1
    fi
    origin="$(git -C "$clone" config --get remote.origin.url 2>/dev/null || true)"
    if [ -n "${METASWARM_REPO_URL:-}" ] && [ "$origin" != "$url" ]; then
      warn "the clone's origin is $origin; METASWARM_REPO_URL is only used for the first install"
    fi
    say "Updating $clone ..."
    git -C "$clone" fetch origin "$ref" </dev/null || { err "git fetch of '$ref' failed; the install was left as it was"; return 1; }
    # Checked before the checkout, so a ref that cannot be installed does not move the clone.
    for need in skills commands agents .opencode/lib/generate-agents.sh; do
      git -C "$clone" cat-file -e "FETCH_HEAD:$need" 2>/dev/null || { err "'$ref' has no OpenCode support (no $need); the install was left as it was"; return 1; }
    done
    git -C "$clone" checkout --quiet --detach FETCH_HEAD </dev/null || { err "git checkout failed (see above); the install was left as it was"; return 1; }
  else
    say "Cloning $url ..."
    mkdir -p "$(dirname "$clone")" || { err "cannot create $(dirname "$clone")"; return 1; }
    git clone --quiet --branch "$ref" "$url" "$clone" </dev/null || { err "git clone of '$ref' from $url failed"; return 1; }
  fi
  say "Ref:    $ref"
  say "Commit: $(git -C "$clone" rev-parse --short HEAD 2>/dev/null)"
}

# --- Links ---

# unlink_ours <dir> <clone> <physical clone>: remove the symlinks directly under <dir>
# whose text points into the clone. Text comparison, so dangling links count too.
unlink_ours() {
  local dir="$1" l t
  [ -d "$dir" ] || return 0
  for l in "$dir"/*; do
    [ -L "$l" ] || continue
    t="$(readlink "$l")"
    case "$t" in
      "$2"/*|"$3"/*) rm -f -- "$l" || err "cannot remove the old link $l" ;;
    esac
  done
}

LINKED=0
SKIPPED=0
# link_one <source> <target>: never replaces anything
link_one() {
  if [ -L "$2" ] || [ -e "$2" ]; then
    warn "$2 exists and is not a metaswarm link; left as it is, skipping"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  if ln -s "$1" "$2"; then LINKED=$((LINKED + 1)); else err "cannot link $2"; fi
}

link_all() {
  local oc="$1" clone="$2" phys="$3" d f
  unlink_ours "$oc/skills" "$clone" "$phys"
  unlink_ours "$oc/commands" "$clone" "$phys"
  unlink_ours "$oc/plugins" "$clone" "$phys"

  mkdir -p "$oc/skills" "$oc/commands" || { err "cannot create $oc/skills and $oc/commands"; return 0; }
  LINKED=0
  for d in "$clone"/skills/*/; do
    d="${d%/}"
    [ -f "$d/SKILL.md" ] || continue
    link_one "$d" "$oc/skills/$(basename "$d")"
  done
  say "Linked $LINKED skills into $oc/skills"

  LINKED=0
  for f in "$clone"/commands/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      # Claude/Codex setup and update entry points, and the alias of start-task
      metaswarm-setup.md|metaswarm-update-version.md|update.md|start.md) continue ;;
    esac
    link_one "$f" "$oc/commands/$(basename "$f")"
  done
  say "Linked $LINKED commands into $oc/commands"

  if [ -f "$clone/.opencode/plugins/metaswarm-session.js" ]; then
    if mkdir -p "$oc/plugins"; then
      LINKED=0
      link_one "$clone/.opencode/plugins/metaswarm-session.js" "$oc/plugins/metaswarm-session.js"
      [ "$LINKED" = 0 ] || say "Linked the session plugin into $oc/plugins"
    else
      err "cannot create $oc/plugins"
    fi
  fi
}

# --- opencode.json ---

# config_has <text> <file>...: one of the files contains <text>, as written or JSON-escaped
config_has() {
  local raw="$1" esc f
  esc="$(json_str "$1")"
  shift
  for f in "$@"; do
    [ -f "$f" ] || continue
    grep -qF -- "$raw" "$f" && return 0
    grep -qF -- "$esc" "$f" && return 0
  done
  return 1
}

configure() {
  local oc="$1" clone="$2" phys="$3"
  local inst="$clone/.opencode/OPENCODE.md" srv="$clone/.opencode/mcp/beads-mcp-server.ts"
  local cfg="$oc/opencode.json" cfgc="$oc/opencode.jsonc" have_srv=0 tmp existing
  [ -f "$srv" ] && have_srv=1

  if [ ! -e "$cfg" ] && [ ! -L "$cfg" ] && [ ! -e "$cfgc" ] && [ ! -L "$cfgc" ]; then
    tmp="$cfg.tmp.$$"
    {
      echo '{'
      echo '  "$schema": "https://opencode.ai/config.json",'
      if [ "$have_srv" = 1 ]; then
        echo "  \"instructions\": [$(json_str "$inst")],"
        echo '  "mcp": {'
        echo '    "servers": {'
        echo '      "beads": {'
        echo '        "type": "local",'
        echo "        \"command\": [\"node\", $(json_str "$srv")],"
        echo '        "enabled": true'
        echo '      }'
        echo '    }'
        echo '  }'
      else
        echo "  \"instructions\": [$(json_str "$inst")]"
      fi
      echo '}'
    } > "$tmp" && mv -- "$tmp" "$cfg" || { rm -f -- "$tmp"; err "cannot write $cfg"; return 0; }
    say "Wrote $cfg"
    return 0
  fi

  # A config exists: it is the user's. Say what is missing, change nothing.
  existing="$cfg"
  [ -e "$cfg" ] || existing="$cfgc"
  if ! config_has "$inst" "$cfg" "$cfgc" && ! config_has "$phys/.opencode/OPENCODE.md" "$cfg" "$cfgc"; then
    echo ""
    say "$existing does not load the metaswarm instructions. Add this entry to it"
    say "(or add the path to the \"instructions\" array it already has):"
    echo ""
    echo "    \"instructions\": [$(json_str "$inst")]"
  fi
  if [ "$have_srv" = 1 ] && ! config_has "$srv" "$cfg" "$cfgc" && ! config_has "$phys/.opencode/mcp/beads-mcp-server.ts" "$cfg" "$cfgc"; then
    echo ""
    say "$existing does not start the BEADS MCP server. Add this entry to it"
    say "(or add \"beads\" to the \"mcp\" \"servers\" object it already has):"
    echo ""
    echo "    \"mcp\": { \"servers\": { \"beads\": { \"type\": \"local\", \"command\": [\"node\", $(json_str "$srv")], \"enabled\": true } } }"
  fi
}

# --- Install ---

install() {
  local from="$1" oc clone phys url ref agents_rc=0 fresh=0
  oc="$(oc_dir)" || exit 1
  url="${METASWARM_REPO_URL:-$DEFAULT_REPO_URL}"
  ref="${METASWARM_REF:-$DEFAULT_REF}"

  echo ""
  echo "  metaswarm — OpenCode installer"
  echo "  =============================="
  echo ""

  if [ -n "$from" ]; then
    clone="$(abs_dir "$from")" || die "--from: no such directory: $from"
    is_checkout "$clone" || die "--from: $clone is not a metaswarm checkout with OpenCode support (needs skills/, commands/, agents/ and .opencode/lib/generate-agents.sh)"
    say "Using the local checkout from --from: $clone (git is not run)"
  else
    clone="$oc/metaswarm"
    if [ ! -e "$clone" ] && [ ! -L "$clone" ]; then fresh=1; fi
    update_clone "$clone" "$url" "$ref" || exit 1
    if ! is_checkout "$clone"; then
      # An existing clone was checked before its checkout, so this is a first clone.
      [ "$fresh" = 1 ] || die "$clone at '$ref' has no OpenCode support (needs skills/, commands/, agents/ and .opencode/lib/generate-agents.sh)"
      die "'$ref' has no OpenCode support (needs skills/, commands/, agents/ and .opencode/lib/generate-agents.sh). It was cloned to $clone, and nothing else was installed. Run the installer again with METASWARM_REF set to a ref that supports OpenCode."
    fi
  fi
  phys="$(phys_dir "$clone")" || die "cannot read $clone"
  say "OpenCode directory: $oc"
  echo ""

  mkdir -p "$oc" || die "cannot create $oc"
  link_all "$oc" "$clone" "$phys"

  echo ""
  say "Generating agents into $oc/agents ..."
  bash "$clone/.opencode/lib/generate-agents.sh" generate --dest "$oc/agents" </dev/null || agents_rc=$?
  if [ "$agents_rc" != 0 ]; then
    err "agent generation failed (exit $agents_rc); the agents in $oc/agents may be missing or out of date"
  fi

  echo ""
  configure "$oc" "$clone" "$phys"

  echo ""
  say "metaswarm's scripts need to know where this checkout is. Put this function in"
  say "your shell profile (~/.bashrc, ~/.zshrc); it sets the two variables for OpenCode"
  say "only, so Claude Code and Codex keep using their own metaswarm:"
  echo ""
  echo "    opencode() { PLUGIN_ROOT=$(sq "$clone") PATH=$(sq "$clone/bin"):\"\$PATH\" command opencode \"\$@\"; }"
  echo ""
  if [ "$FAILED" != 0 ]; then
    say "Finished with errors (see above)."
    echo ""
    exit 1
  fi
  if [ "$SKIPPED" != 0 ]; then
    say "$SKIPPED link(s) were skipped (see the warnings above): those names are NOT served"
    say "from $clone. If they are links to another metaswarm checkout,"
    say "remove them and run this installer again."
    echo ""
  fi
  say "Done! Restart OpenCode, then run /setup in a project to configure it."
  if [ -z "$from" ]; then
    if [ "$ref" = "$DEFAULT_REF" ]; then
      say "To update, run this installer again."
    else
      say "To update, run this installer again with METASWARM_REF=$ref (it is not remembered)."
    fi
  fi
  echo ""
}

# --- Old per-project layout ---

# has_generated_header <file>: the line right after the closing frontmatter --- is a
# metaswarm generated-by header (written by metaswarm-agents.sh generate --host opencode)
has_generated_header() {
  local h
  h="$(awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { if ((getline l) > 0) print l; exit }' < "$1" 2>/dev/null)"
  case "$h" in '<!-- generated-by: metaswarm v'*) return 0 ;; esac
  return 1
}

# is_old_layout <project> <names root or empty>
is_old_layout() {
  local dir="$1" root="$2" f base known n
  if [ -f "$dir/opencode.json" ] && grep -qF '{file:.opencode/' "$dir/opencode.json"; then return 0; fi
  for f in "$dir"/.opencode/agents/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    known=0
    # agents that old installs copied and metaswarm has since renamed
    for n in coder researcher code-review; do
      [ "$base" = "$n-agent.md" ] && known=1
    done
    if [ -n "$root" ] && [ -f "$root/agents/$base" ]; then known=1; fi
    if [ "$known" = 1 ] && ! has_generated_header "$f"; then return 0; fi
  done
  return 1
}

migrate_project() {
  local target="$1" from="$2" dir root="" oc stamp bk n rel moved=0
  dir="$(abs_dir "$target")" || die "--migrate-project: no such directory: $target"
  if [ -n "$from" ]; then
    root="$(abs_dir "$from")" || die "--from: no such directory: $from"
    [ -d "$root/agents" ] || die "--from: $root has no agents/ directory"
  else
    oc="$(oc_dir)" || exit 1
    if [ -d "$oc/metaswarm/agents" ]; then root="$oc/metaswarm"; fi
  fi

  echo ""
  if ! is_old_layout "$dir" "$root"; then
    say "$dir is not an old metaswarm OpenCode layout; nothing moved."
    echo ""
    return 0
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  bk="$dir/.metaswarm/migrate-backup-$stamp"
  n=1
  while [ -e "$bk" ] || [ -L "$bk" ]; do
    n=$((n + 1))
    bk="$dir/.metaswarm/migrate-backup-$stamp-$n"
  done
  mkdir -p "$bk" || die "cannot create $bk"

  say "Old metaswarm OpenCode layout found in $dir"
  say "Moving its files to $bk (nothing is deleted):"
  for rel in opencode.json .opencode/commands .opencode/agents .opencode/skills .opencode/OPENCODE.md \
             .opencode/plugins/metaswarm-session.js scripts/beads-mcp-server.ts; do
    if [ ! -e "$dir/$rel" ] && [ ! -L "$dir/$rel" ]; then continue; fi
    if mkdir -p "$(dirname "$bk/$rel")" && mv -- "$dir/$rel" "$bk/$rel"; then
      say "  moved $rel"
      moved=$((moved + 1))
    else
      err "could not move $rel"
    fi
  done
  echo ""
  if [ "$FAILED" != 0 ]; then
    say "Finished with errors (see above); $moved item(s) moved."
    echo ""
    exit 1
  fi
  say "Anything of your own in those files (your own agents, commands or config"
  say "settings) is in the backup: copy it back by hand."
  say "Next: make sure the global install is in place (run this installer with no"
  say "options), then open the project in OpenCode, run /setup and choose Re-run."
  echo ""
}

main() {
  local from="" migrate="" have_from=0 have_migrate=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)
        [ $# -ge 2 ] && [ -n "$2" ] && [ "$have_from" = 0 ] || usage
        from="$2"; have_from=1; shift 2 ;;
      --migrate-project)
        [ $# -ge 2 ] && [ -n "$2" ] && [ "$have_migrate" = 0 ] || usage
        migrate="$2"; have_migrate=1; shift 2 ;;
      -h|--help) usage_text; exit 0 ;;
      *) usage ;;
    esac
  done
  unset CDPATH
  if [ "$have_migrate" = 1 ]; then
    migrate_project "$migrate" "$from"
  else
    install "$from"
  fi
}

main "$@"
