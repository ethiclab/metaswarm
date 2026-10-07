#!/usr/bin/env npx tsx
/**
 * BEADS MCP Server
 *
 * Exposes BEADS functionality as MCP (Model Context Protocol) tools and resources.
 * Works with OpenCode, Claude Code, and any MCP-compatible client.
 *
 * Usage:
 *   npx tsx scripts/beads-mcp-server.ts
 *
 * Configure in opencode.json:
 *   "mcp": {
 *     "beads": {
 *       "type": "local",
 *       "command": ["npx", "tsx", "scripts/beads-mcp-server.ts"],
 *       "cwd": "/path/to/project",
 *       "enabled": true
 *     }
 *   }
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ListResourcesRequestSchema,
  ReadResourceRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execSync } from "child_process";
import { existsSync, readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const PROJECT_ROOT = join(__dirname, "..");

// =============================================================================
// Types
// =============================================================================

interface BeadsIssue {
  id: string;
  title: string;
  status: "open" | "in_progress" | "done" | "blocked";
  tags: string[];
  description: string;
  createdAt: string;
  updatedAt: string;
}

interface BeadsKnowledgeEntry {
  type: "pattern" | "gotcha" | "decision" | "api-behavior" | "codebase-fact" | "anti-pattern" | "fact";
  title: string;
  content: string;
  tags: string[];
  file?: string;
  line?: number;
}

interface PrimeResult {
  entries: BeadsKnowledgeEntry[];
  summary: string;
}

// =============================================================================
// BEADS CLI Wrapper
// =============================================================================

function runBeads(args: string[]): string {
  try {
    // Try to find bd in PATH first
    let bdCmd = "bd";
    try {
      execSync("which bd", { stdio: "ignore" });
    } catch {
      // Try common locations
      const candidates = [
        join(process.env.HOME || "", ".local", "bin", "bd"),
        join(process.env.HOME || "", ".cargo", "bin", "bd"),
        "/usr/local/bin/bd",
      ];
      for (const c of candidates) {
        if (existsSync(c)) {
          bdCmd = c;
          break;
        }
      }
    }
    const output = execSync([bdCmd, ...args].join(" "), {
      cwd: PROJECT_ROOT,
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return output.trim();
  } catch (e: any) {
    // bd returns non-zero for some commands (like `bd ready` with no results)
    if (e.stdout) return e.stdout.toString().trim();
    throw new Error(`bd command failed: ${e.message}`);
  }
}

function beadsReady(): BeadsIssue[] {
  try {
    const output = runBeads(["ready", "--json"]);
    if (!output) return [];
    return JSON.parse(output);
  } catch {
    return [];
  }
}

function beadsShow(id: string): BeadsIssue | null {
  try {
    const output = runBeads(["show", id, "--json"]);
    if (!output) return null;
    return JSON.parse(output);
  } catch {
    return null;
  }
}

function beadsPrime(query?: string): PrimeResult {
  try {
    const args = ["prime"];
    if (query) args.push(query);
    const output = runBeads(args);
    if (!output) return { entries: [], summary: "No relevant knowledge found" };
    return JSON.parse(output);
  } catch {
    return { entries: [], summary: "BEADS prime failed" };
  }
}

function beadsSync(): { pushed: number; pulled: number } {
  try {
    const output = runBeads(["sync", "--json"]);
    if (!output) return { pushed: 0, pulled: 0 };
    return JSON.parse(output);
  } catch {
    return { pushed: 0, pulled: 0 };
  }
}

function beadsKnowledgeList(type?: string): BeadsKnowledgeEntry[] {
  try {
    const args = ["knowledge", "list"];
    if (type) args.push("--type", type);
    const output = runBeads(args);
    if (!output) return [];
    return JSON.parse(output);
  } catch {
    return [];
  }
}

// =============================================================================
// MCP Server
// =============================================================================

const server = new Server(
  {
    name: "beads-mcp",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
      resources: {},
    },
  }
);

// List tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "bd_ready",
        description: "Find available work items (issues ready to be claimed)",
        inputSchema: {
          type: "object",
          properties: {},
        },
      },
      {
        name: "bd_show",
        description: "View detailed information about a specific issue",
        inputSchema: {
          type: "object",
          properties: {
            id: { type: "string", description: "Issue ID" },
          },
          required: ["id"],
        },
      },
      {
        name: "bd_prime",
        description: "Load relevant knowledge from BEADS knowledge base for a task",
        inputSchema: {
          type: "object",
          properties: {
            query: { type: "string", description: "Optional query to filter knowledge" },
          },
        },
      },
      {
        name: "bd_sync",
        description: "Sync BEADS knowledge base with remote",
        inputSchema: {
          type: "object",
          properties: {},
        },
      },
      {
        name: "bd_knowledge_list",
        description: "List knowledge base entries by type",
        inputSchema: {
          type: "object",
          properties: {
            type: {
              type: "string",
              enum: ["pattern", "gotcha", "decision", "api-behavior", "codebase-fact", "anti-pattern", "fact"],
              description: "Filter by knowledge type",
            },
          },
        },
      },
    ],
  };
});

// Call tool
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "bd_ready": {
      const issues = beadsReady();
      return {
        content: [
          {
            type: "text",
            text: issues.length === 0
              ? "No available work items found. Run `bd sync` to fetch from remote."
              : JSON.stringify(issues, null, 2),
          },
        ],
      };
    }

    case "bd_show": {
      const { id } = args as { id: string };
      const issue = beadsShow(id);
      return {
        content: [
          {
            type: "text",
            text: issue ? JSON.stringify(issue, null, 2) : `Issue ${id} not found`,
          },
        ],
      };
    }

    case "bd_prime": {
      const { query } = args as { query?: string };
      const result = beadsPrime(query);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(result, null, 2),
          },
        ],
      };
    }

    case "bd_sync": {
      const result = beadsSync();
      return {
        content: [
          {
            type: "text",
            text: `Synced: pushed ${result.pushed}, pulled ${result.pulled}`,
          },
        ],
      };
    }

    case "bd_knowledge_list": {
      const { type } = args as { type?: string };
      const entries = beadsKnowledgeList(type);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(entries, null, 2),
          },
        ],
      };
    }

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

// List resources
server.setRequestHandler(ListResourcesRequestSchema, async () => {
  return {
    resources: [
      {
        uri: "beads://issues/ready",
        name: "Available Issues",
        description: "List of issues ready to be worked on",
        mimeType: "application/json",
      },
      {
        uri: "beads://knowledge/patterns",
        name: "Patterns",
        description: "Coding patterns and best practices",
        mimeType: "application/json",
      },
      {
        uri: "beads://knowledge/gotchas",
        name: "Gotchas",
        description: "Common pitfalls and gotchas",
        mimeType: "application/json",
      },
      {
        uri: "beads://knowledge/decisions",
        name: "Decisions",
        description: "Architectural and technical decisions",
        mimeType: "application/json",
      },
    ],
  };
});

// Read resource
server.setRequestHandler(ReadResourceRequestSchema, async (request) => {
  const { uri } = request.params;

  if (uri === "beads://issues/ready") {
    const issues = beadsReady();
    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify(issues, null, 2),
        },
      ],
    };
  }

  if (uri === "beads://knowledge/patterns") {
    const entries = beadsKnowledgeList("pattern");
    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify(entries, null, 2),
        },
      ],
    };
  }

  if (uri === "beads://knowledge/gotchas") {
    const entries = beadsKnowledgeList("gotcha");
    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify(entries, null, 2),
        },
      ],
    };
  }

  if (uri === "beads://knowledge/decisions") {
    const entries = beadsKnowledgeList("decision");
    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify(entries, null, 2),
        },
      ],
    };
  }

  throw new Error(`Unknown resource: ${uri}`);
});

// Start server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("BEADS MCP Server running on stdio");
}

main().catch((error) => {
  console.error("Server error:", error);
  process.exit(1);
});