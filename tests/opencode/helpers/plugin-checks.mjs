// tests/opencode/helpers/plugin-checks.mjs
// Assertions on the OpenCode session plugin, driven by ../test-opencode-plugin.sh.
//
//   node plugin-checks.mjs <plugin file> <expected root> <work dir>
//
// <plugin file> may be a symlink. <expected root> is the physical path of the
// checkout the plugin file really lives in, or "-" when the file is a stray copy
// that sits in no metaswarm checkout. <work dir> is an empty temp directory.
// Prints one "  PASS: ..." or "  FAIL: ..." line per check; the wrapper counts them.

import { spawnSync } from "node:child_process";
import { mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join, delimiter } from "node:path";
import { pathToFileURL } from "node:url";

const [pluginFile, expectedRoot, workDir] = process.argv.slice(2);
if (!pluginFile || !expectedRoot || !workDir) {
  console.error("usage: plugin-checks.mjs <plugin file> <expected root> <work dir>");
  process.exit(2);
}

const pass = (d) => console.log(`  PASS: ${d}`);
const fail = (d, why) => console.log(`  FAIL: ${d}${why === undefined ? "" : ` (${why})`}`);
const check = (d, cond, why) => (cond ? pass(d) : fail(d, why));
// noThrow <desc> <fn>: fn may be async; returns its value, or undefined when it threw
async function noThrow(d, fn) {
  try {
    const v = await fn();
    pass(d);
    return v;
  } catch (e) {
    fail(d, `threw: ${e && e.message}`);
    return undefined;
  }
}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// --- fixtures -------------------------------------------------------------
const EMPTY = join(workDir, "no-beads");
const BEADS = join(workDir, "with-beads");
mkdirSync(EMPTY, { recursive: true });
mkdirSync(join(BEADS, ".beads", "plans"), { recursive: true });
mkdirSync(join(BEADS, ".beads", "context", "review-history"), { recursive: true });
writeFileSync(join(BEADS, ".beads", "plans", "active-plan.md"), `PLAN-MARKER\n${"p".repeat(6000)}PLAN-TAIL\n`);
for (const n of ["a-oldest.md", "b-second.md", "c-third.md", "d-newest.md"]) {
  writeFileSync(join(BEADS, ".beads", "context", n), `CTX-${n}\n`);
}
writeFileSync(join(BEADS, ".beads", "context", ".hidden.md"), "CTX-HIDDEN\n");
writeFileSync(join(BEADS, ".beads", "context", "review-history", "r1.json"), '{"status":"open"}\n');

// a project whose files sit exactly on the caps, and one whose plan is cut inside
// a surrogate pair
const EDGE = join(workDir, "edge");
mkdirSync(join(EDGE, ".beads", "plans"), { recursive: true });
mkdirSync(join(EDGE, ".beads", "context"), { recursive: true });
writeFileSync(join(EDGE, ".beads", "plans", "active-plan.md"), "x".repeat(3999) + "\u{1F600}" + "PLAN-TAIL");
writeFileSync(join(EDGE, ".beads", "context", "long.md"), "CTX-LONG" + "c".repeat(3000) + "CTX-TAIL");
writeFileSync(join(EDGE, ".beads", "context", "short.md"), "CTX-SHORT\n");
// deep inside a project, and a place with no .beads in any ancestor
const DEEP = join(BEADS, "packages", "app", "src");
mkdirSync(DEEP, { recursive: true });

const NO_ROOT = expectedRoot === "-";
const BIN = join(expectedRoot, "bin");

// --- module shape ---------------------------------------------------------
const mod = await import(pathToFileURL(pluginFile).href);
const plugin = mod.default;
check("the module has a default export and no named export", same(Object.keys(mod), ["default"]), Object.keys(mod).join(","));
check("default export is an object", plugin !== null && typeof plugin === "object", typeof plugin);
check("id is a non-empty string", typeof plugin?.id === "string" && plugin.id.length > 0, String(plugin?.id));
check("setup is a function", typeof plugin?.setup === "function", typeof plugin?.setup);
check("server is a function", typeof plugin?.server === "function", typeof plugin?.server);
check("the default export has exactly id, setup and server", same(Object.keys(plugin ?? {}).sort(), ["id", "server", "setup"]), Object.keys(plugin ?? {}).join(","));

// --- server(): the 1.x entry point ----------------------------------------
const hooks = await noThrow("server(input) does not throw", () => plugin.server({ directory: BEADS, worktree: BEADS }));
check(
  "server() returns exactly shell.env and experimental.session.compacting",
  same(Object.keys(hooks ?? {}).sort(), ["experimental.session.compacting", "shell.env"]),
  Object.keys(hooks ?? {}).join(",")
);
const shellEnv = hooks?.["shell.env"];
const compacting = hooks?.["experimental.session.compacting"];
check("both hooks are functions", typeof shellEnv === "function" && typeof compacting === "function");

if (typeof shellEnv === "function" && NO_ROOT) {
  const out = { env: { PATH: "/usr/bin:/bin", PLUGIN_ROOT: "/somewhere/else", KEEP: "1" } };
  await noThrow("stray copy: shell.env does not throw", () => shellEnv({ cwd: BEADS }, out));
  check("stray copy (no metaswarm checkout above it): shell.env leaves the environment untouched", same(out, { env: { PATH: "/usr/bin:/bin", PLUGIN_ROOT: "/somewhere/else", KEEP: "1" } }), JSON.stringify(out));
  const bare = { env: {} };
  await shellEnv({ cwd: BEADS }, bare);
  check("stray copy: nothing is added to an empty environment", same(bare, { env: {} }), JSON.stringify(bare));
} else if (typeof shellEnv === "function") {
  const out = { env: { PATH: "/usr/bin:/bin", PLUGIN_ROOT: "/somewhere/else", KEEP: "1" } };
  const ret = await noThrow("shell.env does not throw", () => shellEnv({ cwd: BEADS }, out));
  check("shell.env returns nothing (it mutates output.env)", ret === undefined, typeof ret);
  check("shell.env sets PLUGIN_ROOT to the realpath'd checkout, replacing an existing value", out.env.PLUGIN_ROOT === expectedRoot, out.env.PLUGIN_ROOT);
  check("shell.env prepends <root>/bin to PATH", out.env.PATH === `${BIN}${delimiter}/usr/bin:/bin`, out.env.PATH);
  check("shell.env leaves other variables alone", out.env.KEEP === "1" && same(Object.keys(out.env).sort(), ["KEEP", "PATH", "PLUGIN_ROOT"]));
  await shellEnv({ cwd: BEADS }, out);
  check("shell.env is idempotent: bin is not prepended twice", out.env.PATH === `${BIN}${delimiter}/usr/bin:/bin`, out.env.PATH);

  const later = { env: { PATH: `/usr/bin${delimiter}${BIN}${delimiter}/bin` } };
  await shellEnv({ cwd: BEADS }, later);
  check("bin later in PATH but not first: put first", later.env.PATH === `${BIN}${delimiter}/usr/bin${delimiter}${BIN}${delimiter}/bin`, later.env.PATH);

  const saved = process.env.PATH;
  process.env.PATH = "/proc-path/a:/proc-path/b";
  const bare = { env: {} };
  await shellEnv({ cwd: BEADS }, bare);
  check("no PATH in output.env: the process PATH is kept behind bin", bare.env.PATH === `${BIN}${delimiter}/proc-path/a:/proc-path/b`, bare.env.PATH);
  delete process.env.PATH;
  const none = { env: {} };
  await shellEnv({ cwd: BEADS }, none);
  check("no PATH anywhere: PATH is just bin", none.env.PATH === BIN, none.env.PATH);
  process.env.PATH = saved;

  await noThrow("shell.env with no output does not throw", () => shellEnv({ cwd: BEADS }, undefined));
  await noThrow("shell.env with no output.env does not throw", () => shellEnv(undefined, {}));
}

// expectState <desc> <strings>: what the compaction hooks must carry over from BEADS
function expectState(d, texts) {
  const all = texts.join("\n---\n");
  check(`${d}: every entry is a non-empty string`, texts.length > 0 && texts.every((t) => typeof t === "string" && t.length > 0));
  check(`${d}: carries the active plan and names its file`, all.includes("PLAN-MARKER") && all.includes(".beads/plans/active-plan.md"));
  check(`${d}: a long plan is cut and says so`, !all.includes("PLAN-TAIL") && /PLAN-MARKER[^]*\(truncated\)/.test(texts.find((t) => t.includes("PLAN-MARKER")) ?? ""));
  check(`${d}: a short file carries no truncation mark`, !(texts.find((t) => t.includes("CTX-d-newest.md")) ?? "(truncated)").includes("(truncated)"));
  check(`${d}: carries the last three context files`, ["b-second.md", "c-third.md", "d-newest.md"].every((n) => all.includes(`CTX-${n}`)) && !all.includes("CTX-a-oldest.md"));
  check(`${d}: skips hidden files and subdirectories`, !all.includes("CTX-HIDDEN") && !all.includes("review-history"));
}

if (typeof compacting === "function") {
  const out = { context: ["already here"] };
  const ret = await noThrow("compacting hook does not throw", () => compacting({ sessionID: "s1" }, out));
  check("compacting hook returns nothing", ret === undefined, typeof ret);
  check("compacting hook appends to output.context and keeps what was there", Array.isArray(out.context) && out.context[0] === "already here" && out.context.length > 1, String(out.context.length));
  check("compacting hook does not set output.prompt", !("prompt" in out));
  expectState("server compacting", out.context.slice(1));

  const emptyHooks = await plugin.server({ directory: EMPTY, worktree: EMPTY });
  const none = { context: [] };
  await noThrow("compacting hook in a directory with no .beads/ does not throw", () => emptyHooks["experimental.session.compacting"]({ sessionID: "s1" }, none));
  check("no .beads/: nothing is added", same(none, { context: [] }), JSON.stringify(none));

  await noThrow("compacting hook with no output does not throw", () => compacting({ sessionID: "s1" }, undefined));
  const noCtx = {};
  await noThrow("compacting hook with no output.context does not throw", () => compacting(undefined, noCtx));
  check("no output.context: none is invented", same(noCtx, {}), JSON.stringify(noCtx));
}

// --- the project root is the nearest ancestor with .beads -------------------
const lone = (t) => /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(t);
async function serverState(input) {
  const out = { context: [] };
  const h = await plugin.server(input);
  await h["experimental.session.compacting"]({ sessionID: "s1" }, out);
  return out.context;
}
check("server: started in a subdirectory, the plan of the project above is carried", (await serverState({ directory: DEEP, worktree: "/" })).join("\n").includes("PLAN-MARKER"));
check("server: directory outside any project, worktree inside one: the worktree's project is used", (await serverState({ directory: EMPTY, worktree: DEEP })).join("\n").includes("PLAN-MARKER"));
check("server: no .beads in any ancestor: nothing added, no throw", same(await serverState({ directory: join(EMPTY, "nope", "deeper"), worktree: "/" }), []));
await noThrow("server: a directory that is not a string does not throw", () => serverState({ directory: 42, worktree: { a: 1 } }));

const edge = await serverState({ directory: EDGE, worktree: EDGE });
const edgePlan = edge.find((t) => t.includes("active-plan.md")) ?? "";
const edgeLong = edge.find((t) => t.includes("CTX-LONG")) ?? "";
const edgeShort = edge.find((t) => t.includes("CTX-SHORT")) ?? "";
check("a plan cut inside a surrogate pair stays well-formed", edgePlan.includes("x".repeat(3999)) && !edgePlan.includes("PLAN-TAIL") && !lone(edgePlan) && edgePlan.includes("(truncated)"), JSON.stringify(edgePlan.slice(-40)));
check("a long context file is cut at its own cap and says so", edgeLong.includes("CTX-LONG") && !edgeLong.includes("CTX-TAIL") && edgeLong.includes("(truncated)") && edgeLong.length < 1500 + 200, String(edgeLong.length));
check("a short context file is carried whole, unmarked", edgeShort.includes("CTX-SHORT") && !edgeShort.includes("(truncated)"));

// Files that are not regular files must not hang or flood the hook: a FIFO as the
// plan, an endless device behind a symlink as a context file. Run in a child
// process, because a blocking read could not be timed out from here.
const TRAP = join(workDir, "trap");
mkdirSync(join(TRAP, ".beads", "plans"), { recursive: true });
mkdirSync(join(TRAP, ".beads", "context"), { recursive: true });
const fifo = spawnSync("mkfifo", [join(TRAP, ".beads", "plans", "active-plan.md")]);
symlinkSync("/dev/zero", join(TRAP, ".beads", "context", "endless.md"));
writeFileSync(join(TRAP, ".beads", "context", "real.md"), "CTX-REAL\n");
if (fifo.status !== 0) {
  fail("mkfifo is available for the fixture", String(fifo.error ?? fifo.stderr));
} else {
  const script = `
    const plugin = (await import(process.argv[1])).default;
    const out = { context: [] };
    const hooks = await plugin.server({ directory: process.argv[2], worktree: process.argv[2] });
    await hooks["experimental.session.compacting"]({ sessionID: "s" }, out);
    const event = { system: [] };
    let handler;
    await plugin.setup({ location: { directory: process.argv[2] }, session: { async hook(n, f) { handler = f; } } });
    await handler(event);
    process.stdout.write(JSON.stringify({ context: out.context, system: event.system.map((p) => p.text) }));
  `;
  const r = spawnSync(process.execPath, ["--input-type=module", "-e", script, pathToFileURL(pluginFile).href, TRAP], { encoding: "utf8", timeout: 15000, killSignal: "SIGKILL" });
  check("a FIFO plan and a device behind a context symlink do not hang the hooks", r.status === 0 && !r.error, `status=${r.status} signal=${r.signal} ${r.stderr}`);
  let got = { context: [], system: [] };
  try { got = JSON.parse(r.stdout); } catch { /* reported above */ }
  check("only the regular file is carried, by both entry points", got.context.length === 1 && got.context[0].includes("CTX-REAL") && got.system.length === 1 && got.system[0].includes("CTX-REAL"), r.stdout.slice(0, 200));
}

const saveCwd = process.cwd();
process.chdir(DEEP);
const cwdHooks = await noThrow("server(undefined) does not throw", () => plugin.server(undefined));
const cwdOut = { context: [] };
await cwdHooks?.["experimental.session.compacting"]?.({ sessionID: "s1" }, cwdOut);
check("server() with no input starts from the working directory and finds the project above it", cwdOut.context.join("\n").includes("PLAN-MARKER"));
process.chdir(saveCwd);

// --- setup(): the 2.x entry point -----------------------------------------
await noThrow("setup(undefined) does not throw", () => plugin.setup(undefined));
await noThrow("setup({}) does not throw", () => plugin.setup({}));
await noThrow("setup with a session that has no hook does not throw", () => plugin.setup({ location: { directory: BEADS }, session: {} }));
await noThrow("setup with a hook that throws does not throw", () =>
  plugin.setup({ location: { directory: BEADS }, session: { hook() { throw new Error("unknown hook"); } } })
);
await noThrow("setup with a hook that rejects does not throw", () =>
  plugin.setup({ location: { directory: BEADS }, session: { hook: async () => { throw new Error("rejected"); } } })
);

function fakeCtx(directory, projectDirectory) {
  const calls = [];
  const noop = { hook: async () => {}, reload: async () => {} };
  const ctx = {
    options: {},
    location: projectDirectory === undefined ? { directory } : { directory, project: { id: "p", directory: projectDirectory } },
    session: {
      marker: "session",
      async hook(name, fn) {
        // a method that needs its receiver, as a class-based context would
        if (this !== ctx.session) throw new Error("hook called without its receiver");
        calls.push({ name, fn });
      },
    },
    shell: { ...noop },
    skill: { ...noop },
    command: { ...noop },
    agent: { ...noop },
    mcp: { ...noop },
  };
  return { ctx, calls };
}

const real = fakeCtx(BEADS);
const setupRet = await noThrow("setup with a realistic context does not throw", () => plugin.setup(real.ctx));
check("setup returns nothing", setupRet === undefined, typeof setupRet);
check("setup registers exactly one session hook, for compaction", real.calls.length === 1 && real.calls[0].name === "compaction" && typeof real.calls[0].fn === "function", real.calls.map((c) => c.name).join(","));
const handler = real.calls[0]?.fn;
if (typeof handler === "function") {
  const event = { system: [{ type: "text", text: "already here" }] };
  await noThrow("setup's compaction handler does not throw", () => handler(event));
  check("the handler appends {type:'text', text} parts to event.system", event.system.length > 1 && event.system[0].text === "already here" && event.system.slice(1).every((p) => p && p.type === "text" && same(Object.keys(p).sort(), ["text", "type"])));
  expectState("setup compaction", event.system.slice(1).map((p) => p.text));
  await noThrow("the handler with an event that has no system array does not throw", () => handler({}));
  await noThrow("the handler with no event does not throw", () => handler(undefined));
}
const bare = fakeCtx(EMPTY);
await plugin.setup(bare.ctx);
const bareEvent = { system: [] };
await noThrow("setup's compaction handler in a directory with no .beads/ does not throw", () => bare.calls[0]?.fn(bareEvent));
check("no .beads/: the handler adds nothing", same(bareEvent, { system: [] }), JSON.stringify(bareEvent));

async function setupState(directory, projectDirectory) {
  const f = fakeCtx(directory, projectDirectory);
  await plugin.setup(f.ctx);
  const event = { system: [] };
  await f.calls[0]?.fn(event);
  return event.system.map((p) => p.text).join("\n");
}
check("setup: a session in a subdirectory carries the plan of the project above", (await setupState(DEEP)).includes("PLAN-MARKER"));
check("setup: location.directory outside any project, location.project.directory inside one", (await setupState(EMPTY, DEEP)).includes("PLAN-MARKER"));
check("setup: no .beads in any ancestor: nothing added, no throw", (await setupState(join(EMPTY, "nope"), join(EMPTY, "nope"))) === "");
