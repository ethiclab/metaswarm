// tests/opencode/helpers/mcp-checks.mjs
// Drives the BEADS MCP server over stdio, as OpenCode does. Used by
// ../test-opencode-plugin.sh.
//
//   node mcp-checks.mjs <server file> <project dir> <stub bin dir> <stub log>
//
// <project dir> holds a .beads/knowledge fixture; the server is started in a
// subdirectory of it. <stub bin dir> holds a fake `bd` that appends
// "<cwd>|<argc>|<args>" to <stub log>. Prints "  PASS: ..." / "  FAIL: ..." lines.

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { dirname, delimiter, join } from "node:path";

const [serverFile, projectDir, stubDir, stubLog] = process.argv.slice(2);
if (!serverFile || !projectDir || !stubDir || !stubLog) {
  console.error("usage: mcp-checks.mjs <server file> <project dir> <stub bin dir> <stub log>");
  process.exit(2);
}

const TIMEOUT_MS = 10000;
const pass = (d) => console.log(`  PASS: ${d}`);
const fail = (d, why) => console.log(`  FAIL: ${d}${why === undefined ? "" : ` (${why})`}`);
const check = (d, cond, why) => (cond ? pass(d) : fail(d, why));
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const nodeDir = dirname(process.execPath);

const children = [];
// The server is started where a user would start OpenCode: somewhere inside the project.
const startDir = join(projectDir, "packages", "app", "src");
mkdirSync(startDir, { recursive: true });
const projectReal = realpathSync(projectDir);

// start <PATH> <HOME> [cwd] [extra env]: a running server with request/notify/close helpers
function start(pathValue, home, cwd = startDir, extraEnv = {}) {
  const child = spawn(process.execPath, [serverFile], {
    cwd,
    env: { PATH: pathValue, HOME: home, STUB_LOG: stubLog, LC_ALL: "C.UTF-8", ...extraEnv },
    stdio: ["pipe", "pipe", "pipe"],
  });
  children.push(child);
  const waiting = new Map();
  const state = { stdoutLines: [], badLines: [], unsolicited: [], stderr: "", exit: null };
  let buf = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      state.stdoutLines.push(line);
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        state.badLines.push(line);
        continue;
      }
      const w = waiting.get(msg.id);
      if (w) {
        waiting.delete(msg.id);
        w(msg);
      } else {
        state.unsolicited.push(msg);
      }
    }
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (c) => (state.stderr += c));
  const exited = new Promise((resolve) => child.on("exit", (code, signal) => resolve((state.exit = { code, signal }))));
  const withTimeout = (p, what) =>
    Promise.race([p, new Promise((_, reject) => setTimeout(() => reject(new Error(`timeout waiting for ${what}`)), TIMEOUT_MS).unref())]);
  let nextId = 1;
  return {
    state,
    raw(text, id) {
      const p = new Promise((resolve) => waiting.set(id, resolve));
      child.stdin.write(text + "\n");
      return withTimeout(p, `the answer to ${text.slice(0, 40)}`);
    },
    request(method, params) {
      const id = nextId++;
      return this.raw(JSON.stringify({ jsonrpc: "2.0", id, method, ...(params === undefined ? {} : { params }) }), id);
    },
    notify(method) {
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method }) + "\n");
    },
    async close() {
      child.stdin.end();
      try {
        return await withTimeout(exited, "the server to exit");
      } catch {
        child.kill("SIGKILL");
        return null;
      }
    },
  };
}

const textOf = (msg) => msg?.result?.content?.map((c) => c.text).join("\n") ?? "";
const stubCalls = () => (existsSync(stubLog) ? readFileSync(stubLog, "utf8").split("\n").filter(Boolean) : []);

async function main() {
  const s = start(`${stubDir}${delimiter}${nodeDir}`, projectDir);

  // --- handshake ---
  const init = await s.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } });
  check("initialize answers with serverInfo", init.jsonrpc === "2.0" && typeof init.result?.serverInfo?.name === "string" && typeof init.result?.serverInfo?.version === "string", JSON.stringify(init));
  check("initialize echoes the client's protocol version", init.result?.protocolVersion === "2025-06-18", init.result?.protocolVersion);
  check("initialize advertises tools and resources", !!init.result?.capabilities?.tools && !!init.result?.capabilities?.resources);
  s.notify("notifications/initialized");
  const ping = await s.request("ping");
  check("ping answers; the initialized notification got no answer", same(ping.result, {}) && s.state.unsolicited.length === 0, JSON.stringify(s.state.unsolicited));

  const list = await s.request("tools/list");
  const tools = list.result?.tools ?? [];
  check("tools/list returns the five BEADS tools", same(tools.map((t) => t.name).sort(), ["bd_knowledge_list", "bd_prime", "bd_ready", "bd_show", "bd_sync"]), tools.map((t) => t.name).join(","));
  check("every tool has a description and an object input schema", tools.length > 0 && tools.every((t) => typeof t.description === "string" && t.description && t.inputSchema?.type === "object"));

  // --- tools/call against the stub bd ---
  const ready = await s.request("tools/call", { name: "bd_ready", arguments: {} });
  const readyText = textOf(ready);
  check("bd_ready returns the stub's output", readyText.includes("stub-1") && readyText.includes("Stub issue") && ready.result?.isError !== true, readyText);
  check("bd ran `ready --json`", stubCalls().some((l) => l.endsWith("|ready --json")), stubCalls().join(" ; "));
  check("started in a subdirectory, bd runs in the project root (the nearest ancestor with .beads)", stubCalls()[0] === `${projectReal}|2|ready --json`, stubCalls()[0]);

  const show = await s.request("tools/call", { name: "bd_show", arguments: { id: "stub-7" } });
  check("bd_show passes the id and returns the stub's output", textOf(show).includes("shown stub-7") && stubCalls().some((l) => l.endsWith("|show stub-7 --json")), textOf(show));
  const missing = await s.request("tools/call", { name: "bd_show", arguments: { id: "missing-1" } });
  check("a bd failure is reported as a tool error with bd's message", missing.result?.isError === true && textOf(missing).includes("no issue found"), JSON.stringify(missing));
  const partial = await s.request("tools/call", { name: "bd_show", arguments: { id: "partial-1" } });
  check("a non-zero bd exit is an error even with output, and carries stdout and stderr", partial.result?.isError === true && textOf(partial).includes("partial-out") && textOf(partial).includes("partial-err"), JSON.stringify(partial));
  const stdin = await s.request("tools/call", { name: "bd_show", arguments: { id: "stdin-1" } });
  check("bd does not inherit the server's stdin (the protocol stream)", textOf(stdin).includes("stdin:eof"), textOf(stdin));
  const evil = "a;b c$(touch INJECTED)`touch INJECTED2`";
  await s.request("tools/call", { name: "bd_show", arguments: { id: evil } });
  check("an id with shell syntax reaches bd as one argument, unevaluated", stubCalls().includes(`${projectReal}|3|show ${evil} --json`) && !existsSync(join(projectDir, "INJECTED")) && !existsSync(join(projectDir, "INJECTED2")) && !existsSync(join(startDir, "INJECTED")), stubCalls().slice(-1)[0]);
  const big = await s.request("tools/call", { name: "bd_show", arguments: { id: "big-1" } });
  check("output over the buffer limit is an error, not a silently cut result", big.result?.isError === true && /too much output/.test(textOf(big)) && textOf(big).length < 5000, textOf(big).slice(0, 200));
  const before = stubCalls().length;
  const dash = await s.request("tools/call", { name: "bd_show", arguments: { id: "--help" } });
  const noId = await s.request("tools/call", { name: "bd_show", arguments: {} });
  check("bd_show refuses an id that is empty or looks like an option, without running bd", dash.result?.isError === true && noId.result?.isError === true && stubCalls().length === before, `${JSON.stringify(dash)} ${JSON.stringify(noId)}`);

  const prime = await s.request("tools/call", { name: "bd_prime", arguments: {} });
  check("bd_prime returns bd's text output as it is", textOf(prime).includes("# Stub workflow reference") && stubCalls().some((l) => l.endsWith("|prime")), textOf(prime));

  const sync = await s.request("tools/call", { name: "bd_sync", arguments: {} });
  const calls = stubCalls();
  const pull = calls.findIndex((l) => l.endsWith("|dolt pull"));
  const push = calls.findIndex((l) => l.endsWith("|dolt push"));
  check("bd_sync runs `bd dolt pull` then `bd dolt push`", pull >= 0 && push > pull && textOf(sync).includes("pulled-ok") && textOf(sync).includes("pushed-ok"), calls.join(" ; "));
  check("the removed `sync` subcommand is never run", !calls.some((l) => /\|sync( |$)/.test(l)), calls.join(" ; "));
  writeFileSync(`${stubLog}.failpull`, "");
  const nCalls = stubCalls().length;
  const badSync = await s.request("tools/call", { name: "bd_sync", arguments: {} });
  const added = stubCalls().slice(nCalls);
  rmSync(`${stubLog}.failpull`);
  check("bd_sync stops after a failed pull: an error, and no push", badSync.result?.isError === true && textOf(badSync).includes("pull-failed") && added.length === 1 && added[0].endsWith("|dolt pull"), `${JSON.stringify(badSync)} ${added.join(" ; ")}`);

  const beforeKb = stubCalls().length;
  const kbAll = await s.request("tools/call", { name: "bd_knowledge_list", arguments: {} });
  const all = JSON.parse(textOf(kbAll) || "null");
  check("bd_knowledge_list reads .beads/knowledge/*.jsonl of the project root; a FIFO is skipped and an oversized file is read up to the cap", Array.isArray(all) && same(all.map((e) => e.id).sort(), ["api-1", "big-first", "gotcha-1", "pattern-1", "pattern-2"]), textOf(kbAll).slice(0, 300));
  const kbApi = await s.request("tools/call", { name: "bd_knowledge_list", arguments: { type: "api_behavior" } });
  check("the type filter uses the entries' own type values (api_behavior)", same((JSON.parse(textOf(kbApi) || "[]") ?? []).map((e) => e.id), ["api-1"]), textOf(kbApi));
  const typeSchema = tools.find((t) => t.name === "bd_knowledge_list")?.inputSchema?.properties?.type;
  check("the advertised types are those of the knowledge schema", same(typeSchema?.enum, ["api_behavior", "code_quirk", "pattern", "gotcha", "decision", "dependency", "performance", "security"]), JSON.stringify(typeSchema));
  const kbOne = await s.request("tools/call", { name: "bd_knowledge_list", arguments: { type: "gotcha" } });
  const one = JSON.parse(textOf(kbOne) || "null");
  check("bd_knowledge_list filters by type", Array.isArray(one) && same(one.map((e) => e.id), ["gotcha-1"]), textOf(kbOne));
  check("bd_knowledge_list does not run bd", stubCalls().length === beforeKb);

  // --- resources ---
  const res = await s.request("resources/list");
  const uris = (res.result?.resources ?? []).map((r) => r.uri);
  check("resources/list returns the four beads:// resources", same(uris.slice().sort(), ["beads://issues/ready", "beads://knowledge/decisions", "beads://knowledge/gotchas", "beads://knowledge/patterns"]), uris.join(","));
  const tpl = await s.request("resources/templates/list");
  check("resources/templates/list is empty", same(tpl.result, { resourceTemplates: [] }), JSON.stringify(tpl));
  const pat = await s.request("resources/read", { uri: "beads://knowledge/patterns" });
  const patText = pat.result?.contents?.[0]?.text ?? "";
  check("resources/read returns the matching knowledge entries", pat.result?.contents?.[0]?.uri === "beads://knowledge/patterns" && patText.includes("pattern-1") && patText.includes("pattern-2") && !patText.includes("gotcha-1"), patText.slice(0, 300));
  const rdy = await s.request("resources/read", { uri: "beads://issues/ready" });
  check("resources/read of the ready issues returns the stub's output", (rdy.result?.contents?.[0]?.text ?? "").includes("stub-1"), JSON.stringify(rdy));

  // --- errors ---
  const unknownTool = await s.request("tools/call", { name: "bd_nope", arguments: {} });
  check("an unknown tool is a -32602 error", unknownTool.error?.code === -32602, JSON.stringify(unknownTool));
  const unknownRes = await s.request("resources/read", { uri: "beads://nope" });
  check("an unknown resource is a -32602 error", unknownRes.error?.code === -32602, JSON.stringify(unknownRes));
  const unknownMethod = await s.request("no/such/method");
  check("an unknown method is a -32601 error", unknownMethod.error?.code === -32601, JSON.stringify(unknownMethod));
  const parse = await s.raw("{not json", null);
  check("a line that is not JSON is a -32700 error with a null id", parse.error?.code === -32700 && parse.id === null, JSON.stringify(parse));
  for (const [what, line] of [["null", "null"], ["a number", "42"], ["a string", '"hello"'], ["a batch array", '[{"jsonrpc":"2.0","id":1,"method":"ping"}]'], ["an empty array", "[]"]]) {
    const r = await s.raw(line, null);
    check(`${what} as a message is a -32600 error with a null id`, r.error?.code === -32600 && r.id === null, JSON.stringify(r));
  }
  const nUnsolicited = s.state.unsolicited.length;
  s.notify("notifications/cancelled");
  // a response from the client (it has an id and no method) is not a request
  await s.raw('{"jsonrpc":"2.0","id":777,"result":{}}\n{"jsonrpc":"2.0","id":778,"method":"ping"}', 778);
  check("a message without a method is ignored", s.state.unsolicited.length === nUnsolicited, JSON.stringify(s.state.unsolicited.slice(nUnsolicited)));
  const oddInit = await s.request("initialize", { protocolVersion: 123 });
  check("initialize with a protocol version that is not a string answers with the server's own", oddInit.result?.protocolVersion === "2024-11-05", JSON.stringify(oddInit));
  const after = await s.request("ping");
  check("the server still answers after the errors", same(after.result, {}));

  // --- shutdown ---
  const exit = await s.close();
  check("the server exits 0 when stdin closes", exit !== null && exit.code === 0, JSON.stringify(exit));
  check("stdout carried only JSON-RPC lines", s.state.badLines.length === 0 && s.state.stdoutLines.length > 0, s.state.badLines.join(" | "));
  check("no TypeScript or module error on stderr", !/SyntaxError|ERR_|Cannot find/.test(s.state.stderr), s.state.stderr.trim());

  // --- a bd that hangs ---
  const t = start(`${stubDir}${delimiter}${nodeDir}`, projectDir, startDir, { BEADS_MCP_TIMEOUT_MS: "1000" });
  const t0 = Date.now();
  const slow = await t.request("tools/call", { name: "bd_show", arguments: { id: "slow-1" } });
  check("a bd that hangs is stopped and reported as a timeout", slow.result?.isError === true && /timed out/.test(textOf(slow)) && Date.now() - t0 < 8000, `${Date.now() - t0}ms ${JSON.stringify(slow)}`);
  const alive = await t.request("ping");
  check("the server answers after the timeout", same(alive.result, {}));
  await t.close();

  // --- started outside any project ---
  const outside = join(dirname(projectDir), "outside", "deep");
  mkdirSync(outside, { recursive: true });
  const o = start(`${stubDir}${delimiter}${nodeDir}`, projectDir, outside);
  const oKb = await o.request("tools/call", { name: "bd_knowledge_list", arguments: {} });
  check("no .beads in any ancestor: the knowledge list is empty, not an error", textOf(oKb) === "[]" && oKb.result?.isError !== true, JSON.stringify(oKb));
  await o.request("tools/call", { name: "bd_ready", arguments: {} });
  check("no .beads in any ancestor: bd runs in the start directory", stubCalls().slice(-1)[0] === `${realpathSync(outside)}|2|ready --json`, stubCalls().slice(-1)[0]);
  await o.close();

  // --- bd not installed ---
  if (existsSync("/usr/local/bin/bd")) {
    console.log("  note: /usr/local/bin/bd exists; the bd-not-installed case is not run");
  } else {
    const n = start(nodeDir, join(dirname(projectDir), "empty-home"));
    await n.request("initialize", {});
    const r = await n.request("tools/call", { name: "bd_ready", arguments: {} });
    check("without bd the tool call is an error that says bd was not found", r.result?.isError === true && /bd .*not found/.test(textOf(r)), JSON.stringify(r));
    const kb = await n.request("tools/call", { name: "bd_knowledge_list", arguments: { type: "pattern" } });
    check("without bd the knowledge list still works", textOf(kb).includes("pattern-1") && kb.result?.isError !== true, textOf(kb));
    const e = await n.close();
    check("that server exits 0 too", e !== null && e.code === 0, JSON.stringify(e));
  }
}

const guard = setTimeout(() => {
  fail("the MCP checks finished in time", "global timeout");
  for (const c of children) c.kill("SIGKILL");
  process.exit(1);
}, 60000);
main()
  .catch((e) => fail("the MCP checks ran to the end", e && e.message))
  .finally(() => {
    clearTimeout(guard);
    for (const c of children) if (c.exitCode === null && c.signalCode === null) c.kill("SIGKILL");
    process.exit(0);
  });
