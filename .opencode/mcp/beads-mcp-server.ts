#!/usr/bin/env node
/**
 * BEADS MCP server — zero-dependency MCP stdio server for OpenCode.
 *
 * Exposes two things as MCP (Model Context Protocol) tools and resources: the
 * metaswarm knowledge base of the project, and its bd issues. Works with any
 * MCP client.
 *
 * No npm packages: the protocol is implemented directly over newline-delimited
 * JSON-RPC on stdio, and Node.js >= 22.18 runs this .ts file as it is (types are
 * stripped, so only erasable TypeScript syntax may be used here).
 *
 * It lives in the metaswarm checkout and is shared by every project:
 * .opencode/install.sh writes this entry into the global opencode.json, with the
 * absolute path of the checkout:
 *
 *   "mcp": {
 *     "servers": {
 *       "beads": {
 *         "type": "local",
 *         "command": ["node", "<checkout>/.opencode/mcp/beads-mcp-server.ts"],
 *         "enabled": true
 *       }
 *     }
 *   }
 *
 * OpenCode starts local MCP servers in the directory it was launched from, which
 * is often a subdirectory of the project. The project root is the nearest ancestor
 * of that directory that holds a `.beads` directory (the start directory itself
 * when there is none): `bd` runs there and .beads/knowledge/ is read from there.
 *
 * BEADS_MCP_TIMEOUT_MS overrides how long a bd command may run (see below).
 *
 * NOTE: never write logs to stdout — stdout carries the MCP protocol.
 */

import { execFileSync } from "node:child_process";
import { closeSync, existsSync, openSync, readSync, readdirSync, statSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { createInterface } from "node:readline";

const START_DIR = process.cwd();

// Limits on what one call may cost. bd is killed, and the call reported as an
// error, when it runs longer or prints more than this.
const BD_TIMEOUT_MS = 60_000;
const BD_SYNC_TIMEOUT_MS = 300_000; // dolt pull/push talk to a remote
const BD_MAX_OUTPUT_BYTES = 10 * 1024 * 1024;
const KNOWLEDGE_MAX_FILE_BYTES = 5 * 1024 * 1024;

// Looked up on every call, not once: /setup creates .beads while the server runs.
function projectRoot(): string {
  let dir = START_DIR;
  for (;;) {
    if (existsSync(join(dir, ".beads"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return START_DIR;
    dir = parent;
  }
}

function timeoutFor(args: string[]): number {
  const override = Number(process.env.BEADS_MCP_TIMEOUT_MS);
  if (Number.isFinite(override) && override > 0) return override;
  return args[0] === "dolt" ? BD_SYNC_TIMEOUT_MS : BD_TIMEOUT_MS;
}

const SERVER_INFO = { name: "beads-mcp", version: "1.0.0" };
const DEFAULT_PROTOCOL_VERSION = "2024-11-05";
const JSONRPC = "2.0";

// =============================================================================
// Types
// =============================================================================

// One line of .beads/knowledge/*.jsonl. Only `type` is relied on here.
interface KnowledgeEntry {
  type?: string;
  [key: string]: unknown;
}

interface RpcMessage {
  jsonrpc: string;
  id?: number | string | null;
  method?: string;
  params?: Record<string, unknown>;
}

interface ToolSpec {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

interface ResourceSpec {
  uri: string;
  name: string;
  description: string;
  mimeType: string;
}

type ToolResult = { content: Array<{ type: "text"; text: string }>; isError?: boolean };
type DispatchOk = { result: unknown };
type DispatchErr = { error: { code: number; message: string } };
type DispatchOutcome = DispatchOk | DispatchErr;

// =============================================================================
// BEADS CLI wrapper (no shell: execFileSync avoids quoting/injection issues)
// =============================================================================

function findBeadsBinary(): string | null {
  const fromPath = (process.env.PATH || "")
    .split(delimiter)
    .filter(Boolean)
    .map((dir) => join(dir, "bd"))
    .find((candidate) => existsSync(candidate));
  if (fromPath) return fromPath;

  const candidates = [
    join(process.env.HOME || "", ".local", "bin", "bd"),
    join(process.env.HOME || "", ".cargo", "bin", "bd"),
    "/usr/local/bin/bd",
  ];
  return candidates.find((candidate) => existsSync(candidate)) || null;
}

// Run bd in the project root and return its stdout. No shell is involved and bd
// gets no stdin (the server's stdin is the protocol stream). Throws, with what bd
// printed, when bd is missing, exits non-zero, runs too long or prints too much.
function runBeads(args: string[]): string {
  const bdCmd = findBeadsBinary();
  if (!bdCmd) throw new Error("bd binary not found in PATH; install beads to use this tool");

  const label = `bd ${args.join(" ")}`;
  const timeout = timeoutFor(args);
  try {
    return execFileSync(bdCmd, args, {
      cwd: projectRoot(),
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout,
      killSignal: "SIGKILL",
      maxBuffer: BD_MAX_OUTPUT_BYTES,
    }).trim();
  } catch (e) {
    const err = e as { code?: string; status?: number | null; signal?: string | null; stdout?: string; stderr?: string; message?: string };
    if (err.code === "ETIMEDOUT") throw new Error(`${label} timed out after ${Math.round(timeout / 1000)} s and was stopped`);
    if (err.code === "ENOBUFS") throw new Error(`${label} printed too much output (more than ${BD_MAX_OUTPUT_BYTES} bytes) and was stopped`);
    const stdout = (err.stdout || "").toString().trim();
    const stderr = (err.stderr || "").toString().trim();
    const how = typeof err.status === "number" ? `exited with status ${err.status}` : err.signal ? `was stopped by ${err.signal}` : `failed: ${err.message || "unknown error"}`;
    throw new Error([`${label} ${how}`, stdout && `stdout:\n${stdout}`, stderr && `stderr:\n${stderr}`].filter(Boolean).join("\n"));
  }
}

// bd's output, re-indented when it is JSON and as printed otherwise.
function pretty(output: string): string {
  try {
    return JSON.stringify(JSON.parse(output), null, 2);
  } catch {
    return output;
  }
}

// Up to `maxBytes` of a regular file as text, or null. A FIFO, a device or a
// directory (also behind a symlink) is refused before it is opened, so this never
// blocks; a longer file is cut after its last complete line.
function readBounded(path: string, maxBytes: number): string | null {
  let fd: number | undefined;
  try {
    const st = statSync(path);
    if (!st.isFile()) return null;
    const buf = Buffer.alloc(Math.min(st.size, maxBytes));
    fd = openSync(path, "r");
    let got = 0;
    while (got < buf.length) {
      const n = readSync(fd, buf, got, buf.length - got, got);
      if (n <= 0) break;
      got += n;
    }
    const text = buf.toString("utf-8", 0, got);
    if (got < st.size) {
      console.error(`beads-mcp: ${path} is larger than ${maxBytes} bytes; only its first part is read`);
      return text.slice(0, text.lastIndexOf("\n") + 1);
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

// The metaswarm knowledge base is a set of JSONL files in the project, not
// something bd stores: read it directly. `type` is matched against each entry's
// own "type" field, not the file name. Lines that are not JSON objects are skipped.
function knowledgeList(type?: string): KnowledgeEntry[] {
  const dir = join(projectRoot(), ".beads", "knowledge");
  let files: string[] = [];
  try {
    files = readdirSync(dir).filter((f) => f.endsWith(".jsonl")).sort();
  } catch {
    return [];
  }
  const entries: KnowledgeEntry[] = [];
  for (const file of files) {
    const text = readBounded(join(dir, file), KNOWLEDGE_MAX_FILE_BYTES);
    if (text === null) continue;
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      try {
        const entry = JSON.parse(line) as KnowledgeEntry;
        if (entry && typeof entry === "object" && !Array.isArray(entry) && (!type || entry.type === type)) entries.push(entry);
      } catch {
        /* not a JSON line: skip */
      }
    }
  }
  return entries;
}

// =============================================================================
// Tools & resources catalog
// =============================================================================

const TOOLS: ToolSpec[] = [
  {
    name: "bd_ready",
    description: "Find available work items (issues ready to be claimed)",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "bd_show",
    description: "View detailed information about a specific issue",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string", description: "Issue ID" } },
      required: ["id"],
    },
  },
  {
    name: "bd_prime",
    description: "Print the bd workflow reference and the memories saved with `bd remember`",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "bd_sync",
    description: "Pull then push the bd issue database (`bd dolt pull`, `bd dolt push`); works only if a Dolt remote is configured",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "bd_knowledge_list",
    description: "List the entries of the project's metaswarm knowledge base (.beads/knowledge/*.jsonl), optionally of one type",
    inputSchema: {
      type: "object",
      properties: {
        type: {
          type: "string",
          // the entry types of the knowledge schema (skills/setup/knowledge/README.md)
          enum: ["api_behavior", "code_quirk", "pattern", "gotcha", "decision", "dependency", "performance", "security"],
          description: "Only entries whose \"type\" field has this value",
        },
      },
    },
  },
];

const RESOURCES: ResourceSpec[] = [
  {
    uri: "beads://issues/ready",
    name: "Available Issues",
    description: "List of issues ready to be worked on",
    mimeType: "application/json",
  },
  {
    uri: "beads://knowledge/patterns",
    name: "Patterns",
    description: "Knowledge base entries of type pattern",
    mimeType: "application/json",
  },
  {
    uri: "beads://knowledge/gotchas",
    name: "Gotchas",
    description: "Knowledge base entries of type gotcha",
    mimeType: "application/json",
  },
  {
    uri: "beads://knowledge/decisions",
    name: "Decisions",
    description: "Knowledge base entries of type decision",
    mimeType: "application/json",
  },
];

function textResult(text: string): ToolResult {
  return { content: [{ type: "text", text }] };
}

function errorResult(text: string): ToolResult {
  return { content: [{ type: "text", text }], isError: true };
}

function callTool(name: string, args: Record<string, unknown>): ToolResult {
  if (!TOOLS.some((tool) => tool.name === name)) {
    throw Object.assign(new Error(`Unknown tool: ${name}`), { rpcCode: -32602 });
  }
  try {
    switch (name) {
      case "bd_ready": {
        const output = runBeads(["ready", "--json"]);
        return textResult(output ? pretty(output) : "No available work items found.");
      }
      case "bd_show": {
        const id = typeof args.id === "string" ? args.id.trim() : "";
        // an id is never an option: keep it from being read as one by bd
        if (!id || id.startsWith("-")) return errorResult("bd_show needs an issue id");
        return textResult(pretty(runBeads(["show", id, "--json"])));
      }
      case "bd_prime":
        return textResult(runBeads(["prime"]));
      case "bd_sync": {
        // a failed pull throws: nothing is pushed on top of it
        const pulled = runBeads(["dolt", "pull"]);
        const pushed = runBeads(["dolt", "push"]);
        return textResult(`bd dolt pull:\n${pulled || "(no output)"}\n\nbd dolt push:\n${pushed || "(no output)"}`);
      }
      default:
        return textResult(JSON.stringify(knowledgeList(typeof args.type === "string" ? args.type : undefined), null, 2));
    }
  } catch (e) {
    // A failing bd is a tool result the model can read, not a protocol error.
    return errorResult((e as Error).message || String(e));
  }
}

function readResource(uri: string): { contents: Array<{ uri: string; mimeType: string; text: string }> } {
  let text: string;
  if (uri === "beads://issues/ready") text = pretty(runBeads(["ready", "--json"]) || "[]");
  else if (uri === "beads://knowledge/patterns") text = JSON.stringify(knowledgeList("pattern"), null, 2);
  else if (uri === "beads://knowledge/gotchas") text = JSON.stringify(knowledgeList("gotcha"), null, 2);
  else if (uri === "beads://knowledge/decisions") text = JSON.stringify(knowledgeList("decision"), null, 2);
  else throw Object.assign(new Error(`Unknown resource: ${uri}`), { rpcCode: -32602 });

  return { contents: [{ uri, mimeType: "application/json", text }] };
}

// =============================================================================
// JSON-RPC dispatch
// =============================================================================

async function dispatch(method: string, params: Record<string, unknown>): Promise<DispatchOutcome> {
  try {
    switch (method) {
      case "initialize":
        return {
          result: {
            protocolVersion: typeof params.protocolVersion === "string" && params.protocolVersion ? params.protocolVersion : DEFAULT_PROTOCOL_VERSION,
            capabilities: { tools: {}, resources: {} },
            serverInfo: SERVER_INFO,
          },
        };
      case "ping":
        return { result: {} };
      case "tools/list":
        return { result: { tools: TOOLS } };
      case "tools/call":
        return {
          result: callTool(String(params.name ?? ""), (params.arguments ?? {}) as Record<string, unknown>),
        };
      case "resources/list":
        return { result: { resources: RESOURCES } };
      case "resources/templates/list":
        // We expose plain URIs only: no URI templates.
        return { result: { resourceTemplates: [] } };
      case "resources/read":
        return { result: readResource(String(params.uri ?? "")) };
      default:
        return { error: { code: -32601, message: `Method not found: ${method}` } };
    }
  } catch (e) {
    const err = e as Error & { rpcCode?: number };
    return { error: { code: err.rpcCode ?? -32603, message: err.message || String(e) } };
  }
}

function send(payload: Record<string, unknown>): void {
  process.stdout.write(JSON.stringify(payload) + "\n");
}

// =============================================================================
// Stdio transport (newline-delimited JSON-RPC)
// =============================================================================

function start(): void {
  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });

  rl.on("line", (line: string) => {
    const trimmed = line.trim();
    if (!trimmed) return;

    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      send({ jsonrpc: JSONRPC, id: null, error: { code: -32700, message: "Parse error" } });
      return;
    }
    // Only a single request object is accepted: no batches, no bare values.
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      send({ jsonrpc: JSONRPC, id: null, error: { code: -32600, message: "Invalid Request" } });
      return;
    }
    const msg = parsed as RpcMessage;

    // No method: a response from the client, not a request. Nothing to answer.
    if (typeof msg.method !== "string" || !msg.method) return;
    // Notifications (e.g. notifications/initialized) carry no id: nothing to answer.
    if (msg.id === undefined || msg.id === null) return;

    const params = msg.params !== null && typeof msg.params === "object" && !Array.isArray(msg.params) ? msg.params : {};
    void dispatch(msg.method, params).then((outcome) => {
      send({ jsonrpc: JSONRPC, id: msg.id, ...outcome });
    });
  });

  rl.on("close", () => process.exit(0));

  console.error("BEADS MCP Server running on stdio");
}

start();
