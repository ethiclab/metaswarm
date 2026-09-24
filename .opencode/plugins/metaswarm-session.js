// metaswarm-session.js — session hooks for metaswarm on OpenCode.
//
// Equivalent of Claude Code's session-start.sh for OpenCode:
//   - session.created: verify mandatory metaswarm files exist and log a
//     clear warning if the project is not set up (no prompt injection —
//     OpenCode has no SessionStart context-parts equivalent).
//   - experimental.session.compacting: inject BEADS state (active plan,
//     context files) into the compaction prompt so work survives context
//     compaction.

import { readFileSync, existsSync } from "node:fs"
import { join } from "node:path"

const MANDATORY_FILES = ["opencode.json", ".opencode/OPENCODE.md"]
const BEADS_PLAN = ".beads/plans/active-plan.md"
const BEADS_CONTEXT_DIR = ".beads/context"

export const MetaswarmSession = async ({ client, directory, $ }) => {
  return {
    event: async ({ event }) => {
      if (event.type === "session.created") {
        for (const f of MANDATORY_FILES) {
          if (!existsSync(join(directory, f))) {
            await client.app.log({
              body: {
                service: "metaswarm",
                level: "warn",
                message: `Metaswarm is not fully set up: missing ${f}. Run: npx metaswarm setup --opencode`,
              },
            })
          }
        }
      }
    },
    "experimental.session.compacting": async (input, output) => {
      const parts = []

      if (existsSync(join(directory, BEADS_PLAN))) {
        try {
          const plan = readFileSync(join(directory, BEADS_PLAN), "utf-8")
          if (plan.trim()) {
            parts.push(`## Active Plan (from .beads/plans/active-plan.md)\n${plan.slice(0, 4000)}`)
          }
        } catch {}
      }

      if (existsSync(join(directory, BEADS_CONTEXT_DIR))) {
        try {
          const files = (await $`ls ${BEADS_CONTEXT_DIR}`.quiet().text().catch(() => ""))
            .split("\n")
            .filter(Boolean)
          for (const f of files.slice(-3)) {
            const content = readFileSync(join(directory, BEADS_CONTEXT_DIR, f), "utf-8")
            if (content.trim()) {
              parts.push(`## Context ${f}\n${content.slice(0, 1500)}`)
            }
          }
        } catch {}
      }

      if (parts.length > 0) {
        output.context.push(...parts)
      }
    },
  }
}