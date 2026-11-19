# OpenCode Tool Mapping (Future)

This file maps Claude Code tool names to OpenCode equivalents.
Implementation deferred — see `docs/plans/2026-02-26-plugin-migration-design.md` for details.

| Claude Code Tool | OpenCode Equivalent |
|------------------|---------------------|
| `Task()` | `@mention` |
| `Skill` | Skill tool |

## Role types on this host

metaswarm spawn sites name a phase role through `roleType`. Roster: `design-reviewer`, `plan-reviewer`, `adversarial-reviewer`, `planner`, `researcher`, `coder`, `pr-shepherd-agent`, `knowledge-curator-agent`, `issue-orchestrator`, `swarm-coordinator-agent`.

| Role | Host mechanism | Model source |
|---|---|---|
| any roster role | `@mention` of an OpenCode subagent (`mode: subagent`) defined in `.opencode/agents/<role>.md` | The agent file's `model` key (`provider/model-id`); if unset, subagents use the model of the invoking primary agent |

Source: https://opencode.ai/docs/agents/ (verified). metaswarm writes these files on request: set `roles.<role>.opencode` to a `provider/model-id` in `.metaswarm/models.yaml` and run `metaswarm-agents.sh generate --host opencode`. Each role that has an `opencode` value gets `.opencode/agents/<role>.md` with the role's description, `mode: subagent`, that `model`, and `permission: edit: deny` for the read-only roles; roles without a value get no file, and `generate --host opencode` also removes the generated file of a role whose `opencode` key was removed (a hand-edited one only with `--force`). Only `<role>.md` files for roster roles that carry the generated-by header are touched; other files in `.opencode/agents/` are left alone. `check --host opencode` and `clean --host opencode` report drift and remove the generated files. A project agent overrides a global one of the same name, and a file you wrote yourself (no generated-by header) is never overwritten. Plain `generate` writes only the Claude files. For the global OpenCode install and what was verified on which OpenCode version, see `docs/README.opencode.md`.

**Fallback:** where no such agent file exists, pass the role name through to the host's generic spawn (an `@mention` or the task tool) with the role's `agents/<role>.md` as the instructions. The primary agent's model applies.
