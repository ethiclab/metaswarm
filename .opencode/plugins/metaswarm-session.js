// metaswarm-session.js — metaswarm's session plugin for OpenCode.
//
// Installed once per machine by .opencode/install.sh, which symlinks this file into
// <opencode dir>/plugins/. It is never copied into a project. Zero dependencies.
//
// One default export serves both OpenCode lines:
//   - OpenCode 1.x requires `server` and calls it; it returns the hooks object.
//   - OpenCode 2.x calls `setup(ctx)`.
// Keep it a single default export with no named exports: 2.x rejects a module
// that has no default `{ id, setup }` definition.
//
// What it does:
//   - before a context compaction, hand OpenCode the project's BEADS state (the
//     active plan and the newest context files) so the work survives it;
//   - on 1.x, give shell commands PLUGIN_ROOT and metaswarm's bin/ on PATH.
//
// What is known about the hooks (checked without a model):
//   - OpenCode 1.19.6: both hooks were observed firing, `shell.env` through the
//     pty/shell path and `experimental.session.compacting` through the summarize
//     endpoint.
//   - OpenCode 2.x beta (0.0.0-beta-19271): there is no compaction trigger. The
//     session hooks that build triggers are context, http.request, http.response,
//     model.request, prompt and retry, so the `setup()` registration below is
//     known NOT to fire there. It is kept only as a guarded, forward-compatible
//     no-op; on 2.x, recovery after a compaction relies on the instructions
//     telling the agent to re-read `.beads`.
//
// Nothing in metaswarm depends on these hooks: the installer prints an
// `opencode()` shell function that sets PLUGIN_ROOT and PATH, and the recovery
// steps in the instructions re-read the same .beads files. So no hook may ever
// throw or block: a missing context member, an unreadable file or a file that is
// not a regular file is skipped silently.

import { closeSync, existsSync, openSync, readSync, readdirSync, realpathSync, statSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const BEADS_PLAN = ".beads/plans/active-plan.md";
const BEADS_CONTEXT_DIR = ".beads/context";
const MAX_PLAN_CHARS = 4000;
const MAX_CONTEXT_CHARS = 1500;
const MAX_CONTEXT_FILES = 3;
const TRUNCATED = "\n... (truncated)";

// The metaswarm checkout this file really lives in: two directories above
// .opencode/plugins/. realpath, because OpenCode reaches the file through the
// installer's symlink and a loader may or may not have resolved it already.
// Returns null when that directory is not a metaswarm checkout, which is what
// happens when the file was copied into <opencode dir>/plugins/ instead of linked.
function checkoutRoot() {
  let file = fileURLToPath(import.meta.url);
  try {
    file = realpathSync(file);
  } catch {
    /* keep the path as given */
  }
  const root = dirname(dirname(dirname(file)));
  try {
    if (statSync(join(root, "bin", "metaswarm-agents.sh")).isFile() && statSync(join(root, ".opencode", "install.sh")).isFile()) {
      return root;
    }
  } catch {
    /* a marker is missing */
  }
  return null;
}

const ROOT = checkoutRoot();
const BIN = ROOT === null ? null : join(ROOT, "bin");

// The first `maxChars` characters of a regular file, or null. Never blocks and
// never reads more than it returns: a FIFO, a device or a directory (also behind
// a symlink) is refused before it is opened, and only a bounded prefix is read.
function readHead(path, maxChars) {
  let fd;
  try {
    const st = statSync(path);
    if (!st.isFile()) return null;
    // 4 bytes hold at least one UTF-16 unit, so this prefix decodes to more than
    // maxChars units unless the whole file fits in it.
    const buf = Buffer.alloc(Math.min(st.size, maxChars * 4 + 4));
    fd = openSync(path, "r");
    let got = 0;
    while (got < buf.length) {
      const n = readSync(fd, buf, got, buf.length - got, got);
      if (n <= 0) break;
      got += n;
    }
    let text = buf.toString("utf-8", 0, got);
    if (got < st.size || text.length > maxChars) {
      let end = Math.min(text.length, maxChars);
      // do not cut a surrogate pair in half
      const last = text.charCodeAt(end - 1);
      if (last >= 0xd800 && last <= 0xdbff) end -= 1;
      text = text.slice(0, end) + TRUNCATED;
    }
    return text;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd);
      } catch {
        /* already closed */
      }
    }
  }
}

// BEADS state to carry across a compaction, as a list of text blocks. Plain
// filesystem reads; never throws.
function beadsState(directory) {
  const parts = [];

  const plan = readHead(join(directory, BEADS_PLAN), MAX_PLAN_CHARS);
  if (plan && plan.trim()) {
    parts.push(`## Active Plan (from ${BEADS_PLAN})\n${plan}`);
  }

  let files = [];
  try {
    files = readdirSync(join(directory, BEADS_CONTEXT_DIR))
      .filter((name) => !name.startsWith("."))
      .sort();
  } catch {
    /* no context directory: skip */
  }
  // readHead refuses what is not a regular file, so filter first, then keep the newest
  const blocks = [];
  for (const file of files.reverse()) {
    if (blocks.length === MAX_CONTEXT_FILES) break;
    const content = readHead(join(directory, BEADS_CONTEXT_DIR, file), MAX_CONTEXT_CHARS);
    if (content === null) continue;
    if (content.trim()) {
      blocks.unshift(`## Context ${file} (from ${BEADS_CONTEXT_DIR}/${file})\n${content}`);
    }
  }
  parts.push(...blocks);

  return parts;
}

// The project root for a start directory: its nearest ancestor (itself included)
// that holds a .beads directory. OpenCode hands plugins the directory it was
// started in, which is often a subdirectory of the project.
function nearestBeadsRoot(start) {
  let dir = start;
  for (;;) {
    if (existsSync(join(dir, ".beads"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

// projectRoot(candidates): the first candidate with a project above it, else the
// first candidate itself. The working directory is used only when OpenCode gave
// no directory at all, so that one project's state is never injected into a
// session that runs somewhere else.
function projectRoot(candidates) {
  const starts = candidates.filter((c) => typeof c === "string" && c);
  if (starts.length === 0) starts.push(process.cwd());
  for (const start of starts) {
    const root = nearestBeadsRoot(start);
    if (root !== null) return root;
  }
  return starts[0];
}

// 1.x `shell.env` hook: (input, output) with output.env the variables for the
// shell command about to run. PLUGIN_ROOT is overwritten on purpose: inside
// OpenCode this checkout is the metaswarm that is installed, whatever a Claude
// Code or Codex setup exported. bin/ goes first on PATH, once. When this file is
// not inside a metaswarm checkout (ROOT is null) the environment is left alone.
function shellEnv(_input, output) {
  const env = output?.env;
  if (ROOT === null || !env || typeof env !== "object") return;
  env.PLUGIN_ROOT = ROOT;
  const current = typeof env.PATH === "string" ? env.PATH : process.env.PATH || "";
  if (current.split(delimiter)[0] !== BIN) {
    env.PATH = current ? `${BIN}${delimiter}${current}` : BIN;
  } else {
    env.PATH = current;
  }
}

export default {
  id: "metaswarm-session",

  // OpenCode 2.x. `ctx.session.hook("compaction", ...)` is what metaswarm's earlier
  // per-project plugin registered. See the header: the 2.x beta never triggers it.
  // Do not move this to the "context" hook, which runs on every model request.
  async setup(ctx) {
    try {
      const starts = [ctx?.location?.directory, ctx?.location?.project?.directory];
      const session = ctx?.session;
      if (typeof session?.hook !== "function") return;
      await session.hook("compaction", (event) => {
        try {
          if (!Array.isArray(event?.system)) return;
          for (const text of beadsState(projectRoot(starts))) {
            event.system.push({ type: "text", text });
          }
        } catch {
          /* best-effort */
        }
      });
    } catch {
      /* best-effort: never fail the plugin load */
    }
  },

  // OpenCode 1.x. Hook signatures are those of @opencode-ai/plugin 1.19.6.
  async server(input) {
    const starts = [input?.directory, input?.worktree];
    return {
      "shell.env": async (hookInput, output) => {
        try {
          shellEnv(hookInput, output);
        } catch {
          /* best-effort */
        }
      },
      // output.context: strings appended to OpenCode's own compaction prompt.
      "experimental.session.compacting": async (_hookInput, output) => {
        try {
          if (!Array.isArray(output?.context)) return;
          for (const text of beadsState(projectRoot(starts))) {
            output.context.push(text);
          }
        } catch {
          /* best-effort */
        }
      },
    };
  },
};
