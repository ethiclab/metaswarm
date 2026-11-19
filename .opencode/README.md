# metaswarm for OpenCode

This is a fork distribution. Upstream metaswarm (`dsifry/metaswarm`) does not ship OpenCode support.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ethiclab/metaswarm/opencode/.opencode/install.sh | bash
```

Once per machine. The installer clones metaswarm into `~/.config/opencode/metaswarm`, links its skills and commands into `~/.config/opencode/`, generates its agents there, and writes `opencode.json` if you have none. It never replaces a file that is not metaswarm's. Then it prints a shell function to put in your profile.

Run the same command again to update.

Then, in a project, start OpenCode and run `/setup`.

Full guide (update, old-layout migration, removal, supported versions): [docs/README.opencode.md](../docs/README.opencode.md).

## Files here

| File | Purpose |
|---|---|
| `install.sh` | The installer. `--help` lists its options |
| `OPENCODE.md` | Instructions loaded into every OpenCode session through the `instructions` config entry |
| `lib/generate-agents.sh` | Renders `agents/*.md` as OpenCode subagents; called by the installer |
