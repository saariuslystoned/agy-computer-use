import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createComputerUseServer } from "../src/index.js";
import { MockHostClient } from "../src/host-client.js";

describe("Computer Use MCP Server Bridge", () => {
  test("Performs handshake and status check correctly", async () => {
    const mockClient = new MockHostClient();
    const hs = await mockClient.request("handshake");
    assert.equal(hs.success, true);
    assert.equal(hs.data?.protocol_version, "1.0");

    const resp = await mockClient.request("status");
    assert.equal(resp.success, true);
    assert.equal(resp.data?.connected, true);
    assert.equal(resp.data?.accessibility_trusted, true);
  });

  test("Executes observe and click workflow returning post_action_observation", async () => {
    const mockClient = new MockHostClient();

    // 1. Observe
    const obsResp = await mockClient.request("observe", { display_id: 1 });
    assert.equal(obsResp.success, true);
    const capId1 = obsResp.data?.capture_id as string;
    assert.ok(capId1);

    // 2. Click with valid capture_id
    const clickResp = await mockClient.request("click", {
      x: 500,
      y: 500,
      button: "left",
      click_count: 1,
      capture_id: capId1
    });
    assert.equal(clickResp.success, true);
    assert.equal(clickResp.data?.status, "verified");

    // Post-action observation check
    const postObs = clickResp.data?.post_action_observation as any;
    assert.ok(postObs);
    const capId2 = postObs.capture_id as string;
    assert.ok(capId2);
    assert.notEqual(capId1, capId2);

    // 3. Second click with old capId1 should fail with STALE_CAPTURE
    const staleResp = await mockClient.request("click", {
      x: 500,
      y: 500,
      capture_id: capId1
    });
    assert.equal(staleResp.success, false);
    assert.equal(staleResp.error?.code, "STALE_CAPTURE");

    // 4. Click with new post-action capId2 should succeed
    const click2Resp = await mockClient.request("click", {
      x: 500,
      y: 500,
      capture_id: capId2
    });
    assert.equal(click2Resp.success, true);
  });

  test("Fetches AX tree with subrole redacted password fields", async () => {
    const mockClient = new MockHostClient();
    const axResp = await mockClient.request("ax_tree", { max_depth: 5 });

    assert.equal(axResp.success, true);
    const rootNode = axResp.data as any;
    assert.equal(rootNode.role, "AXApplication");

    const winNode = rootNode.children?.[0];
    const passNode = winNode?.children?.find((c: any) => c.subrole === "AXSecureTextField");
    assert.ok(passNode);
    assert.equal(passNode.value, "[REDACTED]");
  });
});
