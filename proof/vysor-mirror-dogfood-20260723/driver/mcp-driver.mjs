#!/usr/bin/env node
// mcp-driver.mjs — minimal MCP stdio client for agy-computer-use dogfood runs.
// Spawns the repo's bin/mcp-server.mjs, exposes tool calls as an async API,
// journals every call/result to events.jsonl, and saves observe JPEGs.
//
// Usage: node mcp-driver.mjs <server-launcher-path> <run-dir> <script-path>
// The script at <script-path> must export: export default async function run(cu) {...}
// where cu = { call, observe, status, journal, runDir, lastCapture }.

import { spawn } from "node:child_process";
import { appendFileSync, writeFileSync, mkdirSync, readdirSync } from "node:fs";
import path from "node:path";

const [, , serverPath, runDir, scriptPath] = process.argv;
if (!serverPath || !runDir || !scriptPath) {
  console.error("usage: node mcp-driver.mjs <server-launcher> <run-dir> <script>");
  process.exit(2);
}
mkdirSync(path.join(runDir, "shots"), { recursive: true });
const eventsPath = path.join(runDir, "events.jsonl");
const heartbeatPath = path.join(runDir, "heartbeat");

function journal(event) {
  const row = { ts: new Date().toISOString(), ...event };
  appendFileSync(eventsPath, JSON.stringify(row) + "\n");
  writeFileSync(heartbeatPath, row.ts + "\n");
  return row;
}

const child = spawn(process.execPath, [serverPath], {
  cwd: path.dirname(path.dirname(serverPath)),
  stdio: ["pipe", "pipe", "pipe"],
});
child.stderr.on("data", (d) => {
  for (const line of d.toString().split("\n")) {
    if (line.trim()) journal({ kind: "server_stderr", line: line.slice(0, 400) });
  }
});

let buf = "";
const pending = new Map();
let nextId = 1;
child.stdout.on("data", (d) => {
  buf += d.toString();
  let idx;
  while ((idx = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, idx);
    buf = buf.slice(idx + 1);
    if (!line.trim()) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      journal({ kind: "protocol_garbage", line: line.slice(0, 200) });
      continue;
    }
    if (msg.id !== undefined && pending.has(msg.id)) {
      const { resolve } = pending.get(msg.id);
      pending.delete(msg.id);
      resolve(msg);
    }
  }
});

function rpc(method, params, timeoutMs = 30000) {
  const id = nextId++;
  const req = { jsonrpc: "2.0", id, method, params };
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`rpc timeout: ${method} (id ${id})`));
    }, timeoutMs);
    pending.set(id, {
      resolve: (msg) => {
        clearTimeout(timer);
        resolve(msg);
      },
    });
    child.stdin.write(JSON.stringify(req) + "\n");
  });
}

let shotCounter = readdirSync(path.join(runDir, "shots")).filter((f) => f.endsWith(".jpg")).length;
const state = { lastCapture: null };

async function call(tool, args = {}, opts = {}) {
  const t0 = Date.now();
  const redactedArgs = { ...args };
  journal({ kind: "tool_call", tool, args: redactedArgs });
  const resp = await rpc("tools/call", { name: tool, arguments: args }, opts.timeoutMs ?? 60000);
  const ms = Date.now() - t0;
  if (resp.error) {
    journal({ kind: "tool_error", tool, ms, error: resp.error });
    throw new Error(`${tool} rpc error: ${JSON.stringify(resp.error)}`);
  }
  const result = resp.result ?? {};
  const contents = result.content ?? [];
  let structured = null;
  let imagePath = null;
  for (const c of contents) {
    if (c.type === "text") {
      try {
        structured = JSON.parse(c.text);
      } catch {
        structured = structured ?? { text: c.text };
      }
    } else if (c.type === "image" && c.data) {
      shotCounter += 1;
      imagePath = path.join(runDir, "shots", `${String(shotCounter).padStart(2, "0")}_${tool}.jpg`);
      writeFileSync(imagePath, Buffer.from(c.data, "base64"));
    }
  }
  const summary = summarize(tool, structured);
  journal({ kind: "tool_result", tool, ms, is_error: result.isError ?? false, image: imagePath ? path.basename(imagePath) : null, summary });
  if (result.isError) {
    throw new Error(`${tool} tool error: ${JSON.stringify(summary).slice(0, 500)}`);
  }
  if (structured && structured.capture_id) {
    state.lastCapture = {
      capture_id: structured.capture_id,
      topology_version: structured.topology_version ?? null,
    };
  }
  return { structured, imagePath, raw: result };
}

function summarize(tool, s) {
  if (!s) return null;
  const keep = {};
  for (const k of [
    "status", "ok", "capture_id", "topology_version", "display_id", "width", "height",
    "scale", "error", "error_code", "code", "message", "permission", "screen_recording",
    "accessibility_trusted", "input_mutation_state", "displays", "app", "window_count",
  ]) {
    if (s[k] !== undefined) keep[k] = s[k];
  }
  if (tool === "computer_use_ax_tree" && s) keep.ax_summary = truncateTree(s);
  return Object.keys(keep).length ? keep : { keys: Object.keys(s).slice(0, 12) };
}

function truncateTree(s) {
  const out = [];
  const walk = (n, depth) => {
    if (!n || out.length >= 40) return;
    const b = n.bounds ? ` bounds=${JSON.stringify(n.bounds)}` : "";
    out.push(`${"  ".repeat(depth)}${n.role ?? "?"} "${(n.title ?? n.value ?? "").toString().slice(0, 60)}"${b}`);
    for (const c of n.children ?? []) walk(c, depth + 1);
  };
  walk(s.root ?? s.tree ?? s, 0);
  return out;
}

const cu = {
  call,
  journal,
  runDir,
  get lastCapture() {
    return state.lastCapture;
  },
  status: () => call("computer_use_status"),
  observe: (args = {}) => call("computer_use_observe", args),
};

const { default: run } = await import(path.resolve(scriptPath));
let exitCode = 0;
try {
  const init = await rpc("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "vysor-dogfood-driver", version: "0.1.0" },
  });
  journal({ kind: "initialized", server: init.result?.serverInfo ?? null });
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
  const tools = await rpc("tools/list", {});
  journal({ kind: "tools", names: (tools.result?.tools ?? []).map((t) => t.name) });
  await run(cu);
  journal({ kind: "run_complete", status: "ok" });
} catch (err) {
  exitCode = 1;
  journal({ kind: "run_failed", error: String(err).slice(0, 800) });
} finally {
  child.kill("SIGTERM");
  setTimeout(() => process.exit(exitCode), 500);
}
