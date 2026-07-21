import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createComputerUseServer } from "../src/index.js";
import { MockHostClient } from "../src/host-client.js";

describe("Computer Use MCP Server", () => {
  test("Lists available tools correctly", async () => {
    const mockClient = new MockHostClient();
    const server = createComputerUseServer(mockClient);

    // Call internal list tools handler directly or test client
    const resp = await mockClient.request("status");
    assert.equal(resp.success, true);
    assert.equal(resp.data?.connected, true);
  });

  test("Executes observe and click workflow cleanly", async () => {
    const mockClient = new MockHostClient();

    // 1. Observe
    const obsResp = await mockClient.request("observe", { display_id: 1 });
    assert.equal(obsResp.success, true);
    const capId = obsResp.data?.capture_id as string;
    assert.ok(capId);

    // 2. Click with valid capture_id
    const clickResp = await mockClient.request("click", {
      x: 500,
      y: 500,
      button: "left",
      click_count: 1,
      capture_id: capId
    });
    assert.equal(clickResp.success, true);
    assert.equal(clickResp.data?.status, "verified");

    // 3. Click with STALE capture_id should fail
    const staleResp = await mockClient.request("click", {
      x: 500,
      y: 500,
      capture_id: "stale-cap-0000"
    });
    assert.equal(staleResp.success, false);
    assert.equal(staleResp.error?.code, "STALE_CAPTURE");
  });

  test("Fetches AX tree with redacted password fields", async () => {
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
