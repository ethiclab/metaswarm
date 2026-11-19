# metaswarm for OpenCode

Use metaswarm's skills, commands and agents in [OpenCode](https://opencode.ai).

This is a fork distribution (`ethiclab/metaswarm`, branch `opencode`). Upstream metaswarm (`dsifry/metaswarm`) does not ship OpenCode support.

## Install

Once per machine. Needs `git` and `bash`.

```bash
curl -fsSL https://raw.githubusercontent.com/ethiclab/metaswarm/opencode/.opencode/install.sh | bash
```

Then add the shell function the installer prints to your shell profile (see [The shell function](#the-shell-function)) and restart OpenCode.

### What it does

`<opencode dir>` is `$OPENCODE_CONFIG_DIR` if set, else `$XDG_CONFIG_HOME/opencode`, else `~/.config/opencode`.

| Step | Where | Notes |
|---|---|---|
| Clone metaswarm | `<opencode dir>/metaswarm` | The only copy of metaswarm. Nothing is copied into your projects |
| Link each skill | `<opencode dir>/skills/<name>` | Symlink to the clone's `skills/<name>/` |
| Link each command | `<opencode dir>/commands/<name>.md` | Symlink to the clone's `commands/<name>.md`. The setup and update entry points of other hosts, and the `start` alias, are left out |
| Link the session plugin | `<opencode dir>/plugins/metaswarm-session.js` | Only if the clone contains it |
| Generate the agents | `<opencode dir>/agents/<name>.md` | One subagent per `agents/*.md`, with OpenCode frontmatter and no model, so each uses the session model |
| Write the config | `<opencode dir>/opencode.json` | Only if you have neither `opencode.json` nor `opencode.jsonc` there |

The config has two entries: `instructions` pointing at the clone's `.opencode/OPENCODE.md`, and, if the clone contains the BEADS MCP server, `mcp.servers.beads`. If you already have a config, the installer does not change it. It prints the entries that are missing so you can add them yourself.

The installer never replaces something that is not metaswarm's. A file, a directory or a symlink of yours that sits where a link would go is skipped with a warning. An agent file you wrote yourself with the name of a metaswarm agent is kept, with a warning. A generated agent that you edited by hand is also kept. To overwrite it, run the generator yourself with `--force`:

```bash
bash ~/.config/opencode/metaswarm/.opencode/lib/generate-agents.sh generate --dest ~/.config/opencode/agents --force
```

### The shell function

metaswarm's scripts find the clone through `PLUGIN_ROOT` and expect its `bin/` on `PATH`. The installer prints a function that sets both for OpenCode only. With the default location it is:

```bash
opencode() { PLUGIN_ROOT="$HOME/.config/opencode/metaswarm" PATH="$HOME/.config/opencode/metaswarm/bin":"$PATH" command opencode "$@"; }
```

Put it in `~/.bashrc` or `~/.zshrc`. The installer does not edit your profile.

Do not export `PLUGIN_ROOT` in your profile instead. Claude Code and Codex read the same variable, and an exported value would point them at this clone.

### Install from a local checkout

```bash
bash /path/to/metaswarm/.opencode/install.sh --from /path/to/metaswarm
```

The links point into that checkout and git is not run against it.

## Update

Run the install command again. The installer fetches the branch, checks it out, removes the links of skills and commands that no longer exist, adds the new ones and regenerates the agents. It prints the ref and the commit it installed.

After the first update the clone is checked out detached. If you changed files in it and they block the checkout, the installer stops with git's error and leaves the install as it was.

To follow another branch or tag, set `METASWARM_REF`. It is not remembered: pass it on every run, or the next run goes back to the default branch.

```bash
curl -fsSL https://raw.githubusercontent.com/ethiclab/metaswarm/opencode/.opencode/install.sh | METASWARM_REF=my-branch bash
```

`METASWARM_REPO_URL` selects the repository for the first install. An existing clone keeps its own `origin`.

## Project setup

In your project, start OpenCode (through the shell function) and run:

```text
/setup
```

`/setup` detects the project and writes `AGENTS.md`, which OpenCode reads, and `.coverage-thresholds.json`. Its platform value on OpenCode is `codex`. It needs no OpenCode files in the project. It may also write `.claude/agents/`; OpenCode ignores that directory.

Then start work with `/start-task`.

To give a role its own model, set `roles.<role>.opencode` in `.metaswarm/models.yaml` and run `metaswarm-agents.sh generate --host opencode` in the project. See `skills/start/references/opencode-tools.md`.

## Migrating a project with the old layout

Earlier versions of this fork copied commands, agents and skills into each project and referenced them from the project's `opencode.json` with `{file:.opencode/...}`. Those copies now shadow the global install. Move them out of the way:

```bash
bash ~/.config/opencode/metaswarm/.opencode/install.sh --migrate-project /path/to/project
```

If the project has the old layout, this moves `opencode.json`, `.opencode/commands`, `.opencode/agents`, `.opencode/skills`, `.opencode/OPENCODE.md`, `.opencode/plugins/metaswarm-session.js` and `scripts/beads-mcp-server.ts` into `.metaswarm/migrate-backup-<timestamp>/` inside the project, keeping their relative paths. Nothing is deleted. Anything of your own in those files is in the backup; copy it back by hand. Then run `/setup` in the project and choose Re-run.

A project without the old layout is left untouched.

## Removal

There is no uninstall option. With `OC_DIR` set to your OpenCode directory:

```bash
OC_DIR="$HOME/.config/opencode"

# 1. the symlinks into the clone (after a --from install, put that checkout's path
#    in place of "$OC_DIR/metaswarm")
find "$OC_DIR/skills" "$OC_DIR/commands" "$OC_DIR/plugins" -maxdepth 1 -type l -lname "$OC_DIR/metaswarm/*" -delete

# 2. the generated agents (your own agents, and generated ones you edited, are kept)
bash "$OC_DIR/metaswarm/.opencode/lib/generate-agents.sh" clean --dest "$OC_DIR/agents"

# 3. the clone
rm -rf "$OC_DIR/metaswarm"
```

`find` prints an error for a directory that does not exist (for example `plugins`); that is harmless. If you installed with `--from`, replace `*/metaswarm/*` with a pattern that matches your checkout's path, and skip step 3.

Then remove the two entries from `$OC_DIR/opencode.json`: the `.opencode/OPENCODE.md` path in `instructions`, and `mcp.servers.beads`. Remove the `opencode()` function from your shell profile.

## Supported OpenCode versions

OpenCode 1.19.6 and OpenCode 2.x.

## Verified on

The table of what was checked on which OpenCode version is added with the live tests.
