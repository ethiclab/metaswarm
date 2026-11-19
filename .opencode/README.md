# metaswarm for OpenCode

This is a fork distribution (`ethiclab/metaswarm`, default branch `opencode`). Upstream metaswarm (`dsifry/metaswarm`) does not ship OpenCode support.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ethiclab/metaswarm/opencode/.opencode/install.sh | bash
```

Once per machine. The installer clones metaswarm into `~/.config/opencode/metaswarm`, links its skills and commands into `~/.config/opencode/`, generates its agents there, and writes `opencode.json` if you have none. It never replaces a file that is not metaswarm's. Then it prints a shell function to put in your profile.

To update, run the same `curl` command again. Do not run the clone's own `install.sh` to update: it is the previous version of the installer.

The BEADS MCP server needs `node` 22.18 or newer on `PATH`, and `bd` for its tools.

Then, in a project, start OpenCode and run `/setup`.

Full guide (update, switching checkouts, old-layout migration, removal, what was verified on which OpenCode version): [docs/README.opencode.md](../docs/README.opencode.md).

## Files here

| File | Purpose |
|---|---|
| `install.sh` | The installer. `--help` lists its options |
| `OPENCODE.md` | Instructions loaded into every OpenCode session through the `instructions` config entry |
| `lib/generate-agents.sh` | Renders `agents/*.md` as OpenCode subagents; called by the installer |
| `plugins/metaswarm-session.js` | Session plugin, linked into `<opencode dir>/plugins/`. Hands the project's `.beads/` state to a compaction where OpenCode offers a hook for it |
| `mcp/beads-mcp-server.ts` | BEADS MCP server, started by the `mcp.servers.beads` config entry as `node <file>` |

The live check against real OpenCode binaries is `tests/opencode/test-opencode-live.sh`.
