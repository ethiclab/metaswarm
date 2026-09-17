# OpenCode Integration for MetaSwarm

[OpenCode](https://opencode.ai) is an open-source AI coding assistant. MetaSwarm adds multi-agent orchestration on top of OpenCode via its configuration and agent system.

## Installation

### Prerequisites

- [OpenCode CLI](https://opencode.ai) v1.17.11 or later (`opencode --version`)
- Node.js >= 18

### Install MetaSwarm

```bash
npx metaswarm init --opencode
```

Or install for all supported CLIs:

```bash
npx metaswarm init --all
```

### Project Setup

In your project directory:

```bash
npx metaswarm setup --opencode
```

This generates:

| File | Purpose |
|------|---------|
| `opencode.json` | OpenCode configuration registering commands and agents |
| `.opencode/commands/` | Command templates referenced by `{file:...}` in the config |
| `.opencode/agents/` | Agent prompts referenced by `{file:...}` in the config |
| `.opencode/OPENCODE.md` | Project instructions (loaded via `instructions` field) |

## Workflow

```text
/prime
/start-task <description>
/setup
/review-design
/design-review-gate
/orchestrated-execution
```

1. **`/setup`** — Interactive project setup and configuration
2. **`/prime`** — Load relevant knowledge from BEADS knowledge base
3. **`/start-task`** — Begin tracked work with complexity assessment
4. **`/review-design`** — Architecture-focused design review
5. **`/design-review-gate`** — Full review gate with 5 parallel reviewers (PM, Architect, Designer, Security, CTO)
6. **`/orchestrated-execution`** — Execute work units with 4-phase loop

## Architecture

MetaSwarm uses a hub-and-spoke architecture. OpenCode is one spoke alongside Claude Code, Codex CLI, and Gemini CLI.

```
metaswarm/
  skills/          # Shared orchestration skills (hub)
  commands/        # Canonical command definitions (hub)
  agents/          # Canonical agent definitions (hub)
  templates/       # Platform-specific templates
    opencode.json  # OpenCode config template
    OPENCODE.md    # Instruction file template
  .opencode/       # OpenCode spoke (future: plugin hooks)
    README.md      # This file
```

## Phase 1a Scope

Phase 1a POC is complete with 6 core orchestration commands and all 19 agents registered. The following table shows Phase 1a completion and Phase 1b+ deferred items.

| Area | Phase 1a (Complete) | Phase 1b+ (Deferred) |
|------|-----------|----------|
| Commands | All 15 commands registered (15/15) | none |
| Agents | All 19 agents registered (19/19) | none |
| Plugin hooks | none | BEADS integration, session events, compacting hook |
| Skills discovery | 14 skills via `.opencode/skills/<name>/SKILL.md` | none |
| `.opencode/` structure | commands/, agents/ | plugins/, hooks/ |

## Comparison with Other Platforms

| Feature | Claude Code | Codex CLI | Gemini CLI | OpenCode |
|---------|-------------|-----------|------------|----------|
| Plugin system | `.claude-plugin/` | `.codex-plugin/` | `gemini-extension.json` | `.opencode/` |
| Instructions | `CLAUDE.md` (auto) | `AGENTS.md` (auto) | `GEMINI.md` (auto) | `instructions` array in config |
| Commands | `.claude/commands/*.md` | `.agents/commands/*.md` | TOML files | `opencode.json` + `.opencode/commands/` |
| Agents | Skills-based | `.agents/agents/*.md` | N/A | `opencode.json` + `.opencode/agents/` |
| Marketplace | Claude marketplace | Codex marketplace | Gemini Extensions | Not yet available |
| Install | `claude plugin install` | `codex plugin install` | `gemini extensions install` | `npx metaswarm init --opencode` |

## Testing

```bash
# Validate the config template
node -e "JSON.parse(require('fs').readFileSync('templates/opencode.json','utf-8'))"

# Run the smoke test
bash tests/test-opencode-smoke.sh
```

## Known Limitations

- **Free-tier models may skip parallel review spawns**: DeepSeek V4 Flash and
  Gemini Flash sometimes spawn a single `task` call (e.g. only
  `architect-agent`) instead of the mandated five, or hang under rate limits.
  The setup is correct — a direct prompt asking for five task calls produces
  all five. For deterministic multi-agent gates, use a paid model or rerun
  the command. The `review-design` command documents the required behavior in
  its "Execution (OpenCode) — READ FIRST" section.

## Future Work

- Add `.opencode/plugins/*.ts` for BEADS integration
- Wire `experimental.session.compacting` hook for session management
- Register remaining commands and agents
- Add OpenCode to the hub-and-spoke sync-resources validation pipeline
