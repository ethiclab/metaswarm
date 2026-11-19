# metaswarm for OpenCode

Use metaswarm's skills, commands and agents in [OpenCode](https://opencode.ai).

This is a fork distribution: the repository `ethiclab/metaswarm`, whose default branch for OpenCode is `opencode`. Upstream metaswarm (`dsifry/metaswarm`) does not ship OpenCode support.

## Install

Once per machine. Needs `git` and `bash`. Two more things are needed for the BEADS MCP server (see [The BEADS MCP server](#the-beads-mcp-server)): `node` 22.18 or newer on `PATH`, and `bd`.

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

The installer does not parse your config. It looks for the two paths as text. So a path that appears only inside a comment of an `opencode.jsonc` counts as configured, and no snippet is printed for it. If you commented an entry out, add it back yourself.

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

### The BEADS MCP server

`mcp.servers.beads` starts the clone's `.opencode/mcp/beads-mcp-server.ts` with `node`. It gives the agent tools for the project's metaswarm knowledge base and for its `bd` issues.

- `node` on `PATH` must be 22.18 or newer. That is the first version that runs a `.ts` file as it is. With an older `node` the server cannot start.
- `bd` must be installed for the tools that call it. Without it those tools return an error that says so.
- The server finds the project by walking up from the directory OpenCode was started in to the nearest directory that holds `.beads`. If there is none, it uses the start directory.

### Install from a local checkout

```bash
bash /path/to/metaswarm/.opencode/install.sh --from /path/to/metaswarm
```

The links point into that checkout and git is not run against it.

### Switching to another checkout

The installer only removes links that point into the checkout it is installing from. If you installed from one place and then install from another (a different `--from` path, or the clone after a `--from` install), the old links stay, and the installer reports each of them as skipped. The new checkout is then not the one being served.

Remove the old links first, using the old path, then run the installer again:

```bash
OC_DIR="$HOME/.config/opencode"
OLD="/path/to/the/old/checkout"
find "$OC_DIR/skills" "$OC_DIR/commands" "$OC_DIR/plugins" -maxdepth 1 -type l -lname "$OLD/*" -delete
```

The generated agents need no cleanup; they are rewritten. If you wrote `opencode.json` entries by hand, or the installer wrote the file for the old checkout, change the two paths in it to the new checkout.

## Update

Run the install command again, the `curl` line above. Do not run the `install.sh` inside the clone to update: that is the previous version of the installer, and it would apply the previous version's logic to the new files.

The installer fetches the branch, checks it out, removes the links of skills and commands that no longer exist, adds the new ones and regenerates the agents. It prints the ref and the commit it installed.

After the first update the clone is checked out detached. If you changed files in it and they block the checkout, the installer stops with git's error and leaves the install as it was.

The default branch is `opencode`. To follow another branch or tag, set `METASWARM_REF`. It is not remembered: pass it on every run, or the next run goes back to `opencode`. A ref that has no OpenCode support is refused and the clone stays where it was.

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

There is no uninstall option. Set `OC_DIR` to your OpenCode directory and `SRC` to the checkout the install is served from: the clone, or, after a `--from` install, the path you gave to `--from`.

```bash
OC_DIR="$HOME/.config/opencode"
SRC="$OC_DIR/metaswarm"        # after a --from install: SRC="/path/to/that/checkout"

# 1. the symlinks into the checkout
find "$OC_DIR/skills" "$OC_DIR/commands" "$OC_DIR/plugins" -maxdepth 1 -type l -lname "$SRC/*" -delete

# 2. the generated agents (your own agents, and generated ones you edited, are kept)
bash "$SRC/.opencode/lib/generate-agents.sh" clean --dest "$OC_DIR/agents"

# 3. the clone. Skip this step after a --from install: that checkout is yours
rm -rf "$OC_DIR/metaswarm"
```

`find` prints an error for a directory that does not exist (for example `plugins`); that is harmless.

Then remove the two entries from `$OC_DIR/opencode.json`: the `.opencode/OPENCODE.md` path in `instructions`, and `mcp.servers.beads`. Remove the `opencode()` function from your shell profile.

## Supported OpenCode versions

OpenCode 1.19.6 and OpenCode 2.x.

## Verified on

Everything below was checked without a model or an API key.

| OpenCode | What was checked | Result |
|---|---|---|
| 1.19.6 | The full install of the real metaswarm tree: every agent listed as a subagent, every command, every skill, the instructions entry in the resolved config, the BEADS MCP server connected | Passes (`tests/opencode/test-opencode-live.sh`) |
| 1.19.6 | The session plugin loads and its `shell.env` hook fires: a shell command run in a session sees `PLUGIN_ROOT` and the checkout's `bin/` on `PATH` | Passes (same test) |
| 1.19.6 | The plugin's `experimental.session.compacting` hook | Observed firing once, through the summarize endpoint. Not part of the live test |
| 2.x beta `0.0.0-beta-19271` | The same full install, through the server API, including the instructions entry; the session plugin reported active | Passes (`tests/opencode/test-opencode-live.sh`) |
| 2.x beta `0.0.0-beta-19271` | The clone inside the OpenCode directory adds nothing a second time; a project-level agent with a `model` overrides the global agent of the same name | Passes (same test) |
| 2.0.24 | The mechanisms only, with small fixtures: global commands and skills through symlinks, global agents, the `mcp.servers` config shape, the plugin's `setup` being called | Worked. The full install was not run on 2.0.24 |

Known limits:

- **Compaction on 2.x.** The 2.x beta has no compaction trigger for plugins, so the session plugin's compaction registration does not fire there. After a compaction on 2.x, the agent relies on the instructions (`.opencode/OPENCODE.md` and the project's `AGENTS.md`), which tell it to re-read `.beads/`.
- **`shell.env` on 2.x.** That hook does not exist on 2.x. 2.x has a different shell hook API, which the plugin does not use. This is why the [shell function](#the-shell-function) is the supported way to set `PLUGIN_ROOT`, on both lines.
- **Not verified anywhere:** a complete compaction with a real model.

### Check your own OpenCode

Two checks. The first one tells you whether the install is complete on your OpenCode version. The second one is the only check that the shell function reaches the shells your agent runs.

**1. The live test.** It installs into a temporary home directory and asks your OpenCode what it loaded. It does not touch your real config. The test itself downloads nothing and uses no model. OpenCode 1.x may fetch its own plugin dependencies into the temporary home and may try to reach its model catalogue. The test needs `git`, `node` and `curl`.

```bash
OPENCODE_BIN=/path/to/opencode bash ~/.config/opencode/metaswarm/tests/opencode/test-opencode-live.sh
```

Put the full path of your `opencode` binary in `OPENCODE_BIN`. Without `OPENCODE_BIN`, the test uses the `opencode` it finds on `PATH`. The binary's `--version` decides what runs: the 1.x checks or the 2.x checks. The last line reads `Results: <n> passed, 0 failed` when everything is in place. With no binary at all the test prints a skip message and exits 0.

This is how to confirm the full install on 2.0.24, or on any version not in the table.

**2. `PLUGIN_ROOT` in the agent's shell.** Open a new terminal, so that the `opencode()` function from your profile is defined. Start OpenCode in any project and ask it:

```text
Run this shell command and show me its output: echo "$PLUGIN_ROOT"
```

The output must be the path of the clone, `~/.config/opencode/metaswarm` written out in full (or your `--from` checkout). An empty line means that OpenCode was not started through the function: check that the function is in the profile of the shell you use, and that nothing starts `opencode` by its full path. This check needs a model, so it cannot be part of the live test, and on 2.x nothing else covers it.
