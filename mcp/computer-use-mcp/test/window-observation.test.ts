import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createComputerUseServer } from "../src/index.js";
import { WindowObserveDataSchema } from "../src/schemas.js";
const fixture = () => JSON.parse(readFileSync(new URL("../../../../docs/fixtures/window_observe_response.json", import.meta.url), "utf8"));
async function connected(host: any, session = "window-test") {
  const server = createComputerUseServer(host, session);
  const client = new Client({ name: "window-proof", version: "1" }, { capabilities: {} });
  const [c, s] = InMemoryTransport.createLinkedPair();
  await Promise.all([client.connect(c), server.connect(s)]);
  return { server, client, close: async () => { await client.close(); await server.close(); } };
}
test("window observation preserves selected image, AX identity, geometry and private session; close revokes only that session", async () => {
  const calls: any[] = [];
  const c = await connected({ request: async (method: string, params: any) => {
    calls.push({ method, params });
    return method === "ax_session_close" ? { id: "closed", success: true, data: { closed: true } } : fixture();
  } });
  const result = await c.client.callTool({ name: "computer_use_window_observe", arguments: { app_id: "4242", window_ref: "ax-window-fixture" } });
  assert.equal(result.isError, undefined);
  assert.deepEqual((result.content as any[]).map(x => x.type), ["text", "image"]);
  const data = JSON.parse((result.content as any)[0].text);
  assert.equal(data.window.window_ref, data.state.window_ref);
  assert.equal(data.image.image_data_base64, undefined);
  assert.equal(data.display_normalized_offset_x, 900);
  assert.equal((result.content as any)[1].data, fixture().data.image.image_data_base64);
  await c.close();
  assert.deepEqual(calls, [
    { method: "window_observe", params: { app_id: "4242", window_ref: "ax-window-fixture", session_id: "window-test" } },
    { method: "ax_session_close", params: { session_id: "window-test" } }
  ]);
});
test("window schema rejects wrong targets, timestamps, transform, atomic claims and topology", () => {
  assert.equal(WindowObserveDataSchema.safeParse(fixture().data).success, true);
  for (const mutate of [
    (d: any) => { d.state.window_ref = "foreign"; },
    (d: any) => { d.state.target_app.pid++; },
    (d: any) => { d.image.display_id++; },
    (d: any) => { d.image.capture_id = "global-cap"; },
    (d: any) => { d.image.width_points++; },
    (d: any) => { d.timing.atomic = true; },
    (d: any) => { d.timing.ax_after_ms = d.timing.ax_before_ms - 1; },
    (d: any) => { d.display_normalized_offset_x++; },
    (d: any) => { d.state.tree.bounds.x++; }
  ]) { const data = fixture().data; mutate(data); assert.equal(WindowObserveDataSchema.safeParse(data).success, false); }
});
test("wrong requested window/app and corrupted image fail without exposing authority or images", async () => {
  for (const fault of ["window", "app", "image"]) {
    const response = fixture();
    if (fault === "image") response.data.image.image_sha256 = "0".repeat(64);
    const c = await connected({ request: async () => response });
    try {
      const result = await c.client.callTool({ name: "computer_use_window_observe", arguments: {
        app_id: fault === "app" ? "9999" : "4242", window_ref: fault === "window" ? "foreign-window" : "ax-window-fixture"
      } });
      assert.equal(result.isError, true);
      assert.equal((result.content as any[]).length, 1);
      assert.equal(JSON.parse((result.content as any)[0].text).state, undefined);
    } finally { await c.close(); }
  }
});
test("controllers receive independent native session identities and invalid calls do not open a session", async () => {
  const ids: string[] = [];
  const host = { request: async (method: string, params: any) => {
    if (method === "targets") ids.push(params.session_id);
    return { id: "targets", success: true, data: { apps: [], windows: [], truncated: false, topology_version: fixture().data.image.topology_version } };
  } };
  const a = await connected(host, "owner-a"), b = await connected(host, "owner-b");
  try {
    await a.client.callTool({ name: "computer_use_targets", arguments: {} });
    await b.client.callTool({ name: "computer_use_targets", arguments: {} });
    assert.deepEqual(ids, ["owner-a", "owner-b"]);
  } finally { await a.close(); await b.close(); }
  let calls = 0;
  const invalid = await connected({ request: async () => { calls++; return fixture(); } });
  const result = await invalid.client.callTool({ name: "computer_use_window_observe", arguments: { app_id: "4242", session_id: "impersonate" } });
  await invalid.close();
  assert.equal(result.isError, true); assert.equal(calls, 0);
});
