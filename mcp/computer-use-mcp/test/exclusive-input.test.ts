import { test } from "node:test";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createComputerUseServer } from "../src/index.js";
import { MockHostClient } from "../src/host-client.js";
import { StatusDataSchema, ActionResultDataSchema } from "../src/schemas.js";
const top = "top-sha256-" + "a".repeat(64);
const admission = { lease_id: "exclusive-test", expires_at_ms: Date.now() + 10000, strategy: "exclusive_global_hid", may_affect_pointer_or_focus: true };
async function connect(host: any) {
  const server = createComputerUseServer(host, "exclusive-controller"), client = new Client({ name: "exclusive-proof", version: "1" });
  const [c, s] = InMemoryTransport.createLinkedPair();
  await Promise.all([client.connect(c), server.connect(s)]);
  return { client, close: async () => { await client.close(); await server.close(); } };
}
const data = (result: any) => JSON.parse(result.content[0].text);
test("exclusive admission binds private controller, rejects spoofing and revokes on close", async () => {
  const calls: any[] = [];
  const c = await connect({ request: async (method: string, params: any) => {
    calls.push({ method, params });
    return { id: "x", success: true, data: method === "exclusive_control" ? params.operation === "acquire" ? admission : { released: true } : { closed: true } };
  } });
  for (const args of [{ operation: "acquire", exclusive: true }, { operation: "acquire", app_id: "fixture", duration_ms: 60001 }, { operation: "release", session_id: "spoofed" }]) {
    assert.equal((await c.client.callTool({ name: "computer_use_exclusive_control", arguments: args })).isError, true);
  }
  assert.equal(calls.length, 0);
  const result = await c.client.callTool({ name: "computer_use_exclusive_control", arguments: { operation: "acquire", app_id: "fixture", duration_ms: 5000 } });
  assert.deepEqual(data(result), admission);
  assert.deepEqual(calls[0], { method: "exclusive_control", params: { operation: "acquire", app_id: "fixture", duration_ms: 5000, session_id: "exclusive-controller" } });
  const release = await c.client.callTool({ name: "computer_use_exclusive_control", arguments: { operation: "release" } });
  assert.equal(data(release).released, true);
  await c.close();
  assert.deepEqual(calls.at(-1), { method: "ax_session_close", params: { session_id: "exclusive-controller" } });
});
test("all global tools preserve typed zero-post rejection and never retry", async () => {
  const calls: any[] = [];
  const c = await connect({ request: async (method: string, params: any) => {
    calls.push({ method, params });
    return { id: "x", success: false, error: { code: "OPERATOR_EXCLUSIVE_REQUIRED", message: "Admission required", details: { strategy: "rejected", global_hid_posts: "0" } } };
  } });
  const extras: Record<string, any> = { click: { x: 1, y: 1 }, move: { x: 1, y: 1 }, type: { text: "fixture" }, shortcut: { keys: ["tab"] }, scroll: { x: 1, y: 1, delta_y: 1 }, drag: { start_x: 1, start_y: 1, end_x: 2, end_y: 2 } };
  for (const [action, extra] of Object.entries(extras)) {
    const args = { capture_id: "capture", topology_version: top, intent: "fixture", ...extra };
    const result = await c.client.callTool({ name: "computer_use_" + action, arguments: args });
    assert.equal(result.isError, true);
    assert.equal(data(result).error.code, "OPERATOR_EXCLUSIVE_REQUIRED");
    assert.deepEqual(data(result).error.details, { strategy: "rejected", global_hid_posts: "0" });
    assert.deepEqual(calls.at(-1), { method: action, params: { ...args, session_id: "exclusive-controller" } });
  }
  assert.equal(calls.length, 6); await c.close();
});
test("malformed global receipts remain uncertain without retry", async () => {
  const good = { action_id: "act", capture_id: "capture", status: "dispatched", duration_ms: 1, strategy: "exclusive_global_hid", global_hid_posts: 1 };
  assert.equal(ActionResultDataSchema.safeParse(good).success, true);
  for (const change of [{ strategy: "ax_semantic" }, { strategy: undefined }, { global_hid_posts: 0 }, { global_hid_posts: undefined }]) {
    let calls = 0;
    const c = await connect({ request: async () => { calls++; return { id: "x", success: true, data: { ...good, ...change } }; } });
    const result = await c.client.callTool({ name: "computer_use_move", arguments: { exclusive_lease_id: "exclusive-test", capture_id: "capture", topology_version: top, intent: "fixture", x: 1, y: 1 } });
    assert.equal(data(result).error.code, "OUTCOME_UNKNOWN"); assert.equal(calls, 1); await c.close();
  }
});
test("status separates AX trust from native admission and rejects contradictory mode", async () => {
  const mock = new MockHostClient(); mock.axTrusted = true; mock.axAvailable = true;
  const status = (await mock.request("status")).data!;
  assert.equal(StatusDataSchema.safeParse(status).success, true);
  assert.equal(status.input_isolation_mode, "operator_safe_ax");
  assert.deepEqual(status.supported_action_strategies, ["ax_semantic"]);
  for (const change of [{ input_isolation_mode: undefined }, { host_instance_id: undefined }, { exclusive_admission_required: false }, { input_isolation_mode: "exclusive_global_hid" }, { supported_action_strategies: ["ax_semantic", "exclusive_global_hid"] }]) {
    assert.equal(StatusDataSchema.safeParse({ ...status, ...change }).success, false);
  }
});
test("invalid and wrong-operation admission receipts fail closed", async () => {
  for (const response of [{ released: true }, { ...admission, strategy: "ax_semantic" }, { ...admission, may_affect_pointer_or_focus: false }, { ...admission, lease_id: "" }]) {
    let calls = 0;
    const c = await connect({ request: async () => { calls++; return { id: "x", success: true, data: response }; } });
    const result = await c.client.callTool({ name: "computer_use_exclusive_control", arguments: { operation: "acquire", app_id: "fixture", duration_ms: 1000 } });
    assert.equal(data(result).error.code, "INVALID_RESPONSE_DATA"); assert.equal(calls, 1); await c.close();
  }
});
