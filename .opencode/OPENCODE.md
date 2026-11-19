# metaswarm on OpenCode

metaswarm is installed globally for OpenCode: its skills, commands and subagents are already registered. Its files were written for several hosts, so read them with these rules.

- **Names.** `metaswarm:<name>` and `$name` in metaswarm text both mean the skill or command called `<name>` here. Load the skill with the skill tool, or run `/<name>`.
- **Roles.** `roleType(<role>)` means the subagent called `<role>`. Spawn it by that name (task tool or `@<role>`).
- **Claude-only files.** Ignore `.claude/agents/`, also when `/setup` or `metaswarm-agents.sh generate` writes files there. OpenCode does not read them.
- **Per-role models.** Subagents use the session model. To give a role its own model, set `roles.<role>.opencode` in `.metaswarm/models.yaml` and run `metaswarm-agents.sh generate --host opencode` in the project. Details: `skills/start/references/opencode-tools.md`.
- **Project setup.** In `/setup` the platform value is `codex`. It writes `AGENTS.md`, which OpenCode reads.
- **After a compaction.** After a context compaction, or in a new session on work in progress, re-read `.beads/plans/active-plan.md` (resume only if its `status` is `in-progress`), `.beads/context/project-context.md` and `.beads/context/execution-state.md`, then run `/prime`. Do not assume a hook restored them.
- **Updating.** To update metaswarm, the user runs the install command again: `curl -fsSL https://raw.githubusercontent.com/ethiclab/metaswarm/opencode/.opencode/install.sh | bash`. Do not run the `install.sh` inside the clone for this (it is the previous version of the installer), and do not use `/update` or `npx metaswarm`; they serve other hosts.
