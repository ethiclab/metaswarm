# Project Instructions

This project uses [metaswarm](https://github.com/dsifry/metaswarm), a multi-agent orchestration framework for OpenCode. It provides specialized agents, commands, and quality gates that enforce TDD, coverage thresholds, and spec-driven development.

## How to Work in This Project

### Starting work

Start by priming context with relevant knowledge, then begin tracked work:

```text
/prime
/start-task <task-description>
```

This primes the agent with relevant knowledge, guides you through scoping, and picks the right level of process for the task.

### Design review

After writing a design document, you can request a parallel 5-agent review:

```text
/review-design <path-to-design-doc>
```

The gate spawns five reviewers via the `task` tool — `product-manager-agent`, `architect-agent`, `designer-agent`, `security-design-agent`, `cto-agent` — and aggregates their verdicts. Use `--skip-agent <name>` to skip a reviewer.

### Available Commands

| Command | Purpose |
|---|---|
| `/setup` | Interactive project setup — detects your project, configures metaswarm, writes project-local files |
| `/start-task` | Begin tracked work on a task with complexity assessment |
| `/prime` | Load relevant knowledge from the BEADS knowledge base before starting work |
| `/review-design` | Parallel design review gate — spawns PM, Architect, Designer, Security, and CTO agents |
| `/design-review-gate` | Automatic review gate that runs after brainstorming completes - spawns PM, Architect, Designer, Security, and CTO agents in parallel |
| `/orchestrated-execution` | 4-phase execution loop for work units - IMPLEMENT, VALIDATE, ADVERSARIAL REVIEW, COMMIT |
| `/self-reflect` | Extract learnings from recent work and update the knowledge base |
| `/handoff` | Write a self-contained handoff document so a fresh agent can resume the work |
| `/pr-shepherd <pr>` | Monitor a PR through to merge - handles CI failures, reviews, and thread resolution |
| `/brainstorm` | Refine an idea before implementation |
| `/update` | Update the metaswarm installation |
| `/status` | Show current project setup status and available tools |
| `/handle-pr-comments` | Handle PR review comments |
| `/create-issue` | Create a well-structured GitHub Issue |
| `/external-tools-health` | Check health of external tools (BEADS, GitHub, CI) |

### Available Agents

All 19 metaswarm agents are registered as subagents and spawnable via the `task` tool. Key ones:

| Agent | Purpose |
|---|---|
| `issue-orchestrator` | Main coordinator per issue — spawns sub-agents, runs 4-phase execution loop |
| `architect-agent` | Reviews technical architecture and creates implementation plans |
| `product-manager-agent` | Reviews design documents for use case clarity and product alignment |
| `designer-agent` | Reviews designs for UX, API design, and developer experience |
| `security-design-agent` | Reviews designs for security vulnerabilities before implementation |
| `cto-agent` | Reviews plans for TDD readiness, codebase alignment, and risk |

## Platform Conventions

The metaswarm command and agent prompts are written for Claude Code. When you
follow them, translate these conventions to OpenCode equivalents:

| Claude Code convention | OpenCode equivalent |
|---|---|
| `Task()` subagent spawn | `task` tool with `subagent_type` (e.g. `subagent_type: "architect-agent"`) |
| `@agent-name` mentions | `task` tool with the registered subagent name |
| `@beads start #N` / `@beads approve` | `bd start #N` / `bd approve` (BEADS CLI directly) |
| `CLAUDE.md` instruction file | `AGENTS.md` + this file |
| Team Mode (`TeamCreate`/`SendMessage`) | Not available — always use Task Mode (`task` tool) |

Rules that must not be diluted when translating:

- Adversarial reviewers are ALWAYS fresh `task` tool calls — never reused, never
  resumed, never given prior context.
- Never pass `--dangerously-skip-permissions` or auto-approve write permissions.
- Spawn one `task` call per agent; do not impersonate multiple roles in a
  single agent's response.

## Current Limitations

- BEADS integration is via the `bd` CLI and the `metaswarm-session` plugin
  (setup warnings + state preservation across compaction)