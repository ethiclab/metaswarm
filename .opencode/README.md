# OpenCode Integration

This directory contains the OpenCode integration assets for metaswarm.

## Installation

```bash
npx metaswarm init --opencode
```

Or include OpenCode when installing for all platforms:

```bash
npx metaswarm init --all
```

After installation, run project setup:

```bash
npx metaswarm setup --opencode
```

This generates `opencode.json` and copies the referenced command and agent files into `.opencode/commands/` and `.opencode/agents/`.

## What's Registered

| Type | Count | Items |
|------|-------|-------|
| Commands | 6 | setup, start-task, prime, review-design, design-review-gate, orchestrated-execution |
| Agents | 2 | issue-orchestrator, architect-agent |

## Phase 1a POC Scope

Phase 1a is complete with 6 core orchestration commands and 2 core agents.
Additional commands and agents will be added incrementally in Phase 1b and beyond.

### Deferred to Follow-up PRs

- BEADS integration via `.opencode/plugins`
- Session hooks (`experimental.session.compacting`, session events)
- Skills discovery (`skill` tool wiring)
- `.opencode/plugins/*.ts` plugin system
- Full command roster (remaining 10 commands)
- Full agent roster (remaining 17 agents)
