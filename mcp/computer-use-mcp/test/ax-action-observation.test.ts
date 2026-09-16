import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createComputerUseServer } from "../src/index.js";
import { AXActionInputSchema, AXActionResultDataSchema } from "../src/schemas.js";
import { HostClient } from "../src/host-client.js";

const fixture = (name: string) => JSON.parse(readFileSync(new URL(`../../../../docs/fixtures/${name}.json`, import.meta.url), "utf8"));
const request = fixture("ax_action_observe_request");
const response = fixture("ax_action_observe_response");
async function call(host: HostClient, args: unknown) {
  // Session cleanup is a distinct lifecycle operation. Mutation/read assertions
  // below continue to count every functional request, including any retry.
  const server = createComputerUseServer({ request: async (method, params, signal) => {
    if (method === "ax_session_close") {
      assert.deepEqual(params, { session_id: "test-session" });
      return { id: "closed", success: true, data: { closed: true } };
    }
    return host.request(method, params, signal);
  } }, "test-session");
  const client = new Client({ name: "compound-proof", version: "1" }, { capabilities: {} });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  try { return await client.callTool({ name: "computer_use_ax_action", arguments: args as any }); }
  finally { await client.close(); await server.close(); }
}

test("compound option returns fresh state through exactly one native operation", async () => {
  const calls: Array<{ method: string; params: unknown }> = [];
  const result = await call({ request: async (method, params) => {
    calls.push({ method, params }); return response;
  } }, request.params);
  assert.equal(result.isError, undefined);
  assert.deepEqual(calls, [{ method: "ax_action_observe", params: { ...request.params, session_id: "test-session" } }]);
  const data = JSON.parse((result.content as any)[0].text);
  assert.equal(data.status, "dispatched");
  assert.equal(data.observation.status, "unchanged");
  assert.notEqual(data.ax_snapshot_id, data.observation.state.ax_snapshot_id);
  assert.deepEqual(data.observation.state.tree, response.data.observation.state.tree);
});

test("legacy route is preserved and compound action errors never repeat or trigger bridge reads", async () => {
  let calls = 0;
  await call({ request: async (method) => {
    calls++; assert.equal(method, "ax_action"); return fixture("ax_action_response");
  } }, fixture("ax_action_request").params);
  assert.equal(calls, 1);
  for (const code of ["OUTCOME_UNKNOWN", "USER_INTERVENED", "AX_ACTION_REPLAYED", "UNKNOWN_METHOD"]) {
    calls = 0;
    const result = await call({ request: async () => {
      calls++; return { id: "error", success: false, error: { code, message: "fixture" } };
    } }, request.params);
    assert.equal(result.isError, true);
    assert.equal(JSON.parse((result.content as any)[0].text).error.code, code);
    assert.equal(calls, 1);
  }
});

test("observation errors preserve dispatch and a missing compound result fails closed", async () => {
  for (const status of ["timed_out", "failed"]) {
    const data = structuredClone(response);
    data.data.observation = { status, condition: "snapshot", attempts: 1, elapsed_ms: 100,
      error_code: status === "timed_out" ? "TIMEOUT" : "USER_INTERVENED" };
    const result = await call({ request: async () => data }, request.params);
    assert.equal(result.isError, undefined);
    const returned = JSON.parse((result.content as any)[0].text);
    assert.equal(returned.status, "dispatched");
    assert.equal(returned.observation.status, status);
  }
  const missing = await call({ request: async () => fixture("ax_action_response") }, request.params);
  assert.equal(missing.isError, true);
  assert.equal(JSON.parse((missing.content as any)[0].text).error.code, "OUTCOME_UNKNOWN");
});

test("invalid observation options fail before host dispatch", async () => {
  for (const observe of [null, {}, { condition: "anything", timeout_ms: 100 },
    { condition: "snapshot", timeout_ms: 99 }, { condition: "snapshot", timeout_ms: 2001 },
    { condition: "snapshot", timeout_ms: 100.5 }, { condition: "snapshot", timeout_ms: 100, app_id: "other" }]) {
    const args = { ...request.params, observe };
    assert.equal(AXActionInputSchema.safeParse(args).success, false);
    let calls = 0;
    const result = await call({ request: async () => { calls++; return response; } }, args);
    assert.equal(result.isError, true);
    assert.equal(calls, 0);
  }
  assert.equal(AXActionInputSchema.safeParse({ ...request.params, action: "set_value", value: "" }).success, true);
});

test("schema rejects stale authority and contradictory, partial or oversized observation results", () => {
  assert.equal(AXActionResultDataSchema.safeParse(response.data).success, true);
  const mutations = [
    (d: any) => { d.observation.state.ax_snapshot_id = d.ax_snapshot_id; },
    (d: any) => { d.observation.state.app_instance_ref = d.app_instance_ref; },
    (d: any) => { d.observation.status = "changed"; },
    (d: any) => { d.observation.changes.changed = 1; },
    (d: any) => { d.observation.condition = "semantic_change"; },
    (d: any) => { d.observation.attempts = 0; },
    (d: any) => { d.observation.error_code = "TIMEOUT"; },
    (d: any) => { delete d.observation.state; },
    (d: any) => { d.observation.changes.node_ids = Array(17).fill("id"); },
    (d: any) => { d.observation.state.topology_version = "top-sha256-" + "0".repeat(64); }
  ];
  for (const mutate of mutations) {
    const d = structuredClone(response.data); mutate(d);
    assert.equal(AXActionResultDataSchema.safeParse(d).success, false);
  }
});

test("malformed or request-mismatched compound replies remain uncertain without retry", async () => {
  for (const mutate of [
    (d: any) => { d.observation.status = "changed"; },
    (d: any) => { d.element_ref = "wrong-ref"; },
    (d: any) => { d.observation.condition = "semantic_change"; }
  ]) {
    const reply = structuredClone(response); mutate(reply.data);
    let calls = 0;
    const result = await call({ request: async () => { calls++; return reply; } }, request.params);
    assert.equal(result.isError, true);
    assert.equal(JSON.parse((result.content as any)[0].text).error.code, "OUTCOME_UNKNOWN");
    assert.equal(calls, 1);
  }
});

test("compound socket timeout, cancellation and EOF retain mutation uncertainty with one write", async () => {
  const net = await import("node:net");
  const fs = await import("node:fs");
  const os = await import("node:os");
  const { UnixSocketHostClient } = await import("../src/host-client.js");
  for (const mode of ["timeout", "cancel", "eof"]) {
    const dir = fs.mkdtempSync(`${os.tmpdir()}/compound-`);
    const sock = `${dir}/host.sock`;
    const abort = new AbortController();
    const sockets: import("node:net").Socket[] = [];
    let frames = 0;
    const server = net.createServer({ allowHalfOpen: true }, (socket) => {
      sockets.push(socket);
      socket.once("data", () => {
        frames++;
        if (mode === "cancel") abort.abort();
        if (mode === "eof") socket.end();
      });
    });
    await new Promise<void>((resolve) => server.listen(sock, resolve));
    try {
      const result = await new UnixSocketHostClient(sock, 100).request("ax_action_observe", request.params, abort.signal);
      assert.equal(result.success, false);
      assert.equal(result.error?.code, "OUTCOME_UNKNOWN");
      assert.match(result.error?.message ?? "", /computer_use_ax_tree/);
      assert.equal(frames, 1);
    } finally {
      for (const socket of sockets) socket.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      fs.rmSync(dir, { recursive: true });
    }
  }
});
