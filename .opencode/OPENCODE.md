# metaswarm on OpenCode

metaswarm is installed globally for OpenCode: its skills, commands and subagents are already registered. Its files were written for several hosts, so read them with these rules.

- **Names.** `metaswarm:<name>` and `$name` in metaswarm text both mean the skill or command called `<name>` here. Load the skill with the skill tool, or run `/<name>`.
- **Roles.** `roleType(<role>)` means the subagent called `<role>`. Spawn it by that name (task tool or `@<role>`).
- **Claude-only files.** Ignore `.claude/agents/`, also when `/setup` or `metaswarm-agents.sh generate` writes files there. OpenCode does not read them.
- **Per-role models.** Subagents use the session model. To give a role its own model, set `roles.<role>.opencode` in `.metaswarm/models.yaml` and run `metaswarm-agents.sh generate --host opencode` in the project. Details: `skills/start/references/opencode-tools.md`.
- **Project setup.** In `/setup` the platform value is `codex`. It writes `AGENTS.md`, which OpenCode reads.
- **Updating.** To update metaswarm, re-run the installer (`.opencode/install.sh` in the metaswarm clone). Do not use `/update` or `npx metaswarm`; they serve other hosts.
