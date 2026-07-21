import { test, describe } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createComputerUseServer } from "../src/index.js";
import { MockHostClient } from "../src/host-client.js";

describe("Computer Use MCP Server End-to-End Integration", () => {
  test("Exercises listTools and callTool using official SDK Client and InMemoryTransport linked pair", async () => {
    const mockHost = new MockHostClient();
    const server = createComputerUseServer(mockHost);

    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    const client = new Client(
      { name: "test-client", version: "1.0.0" },
      { capabilities: {} }
    );

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    // 1. List tools
    const toolsResult = await client.listTools();
    assert.ok(toolsResult.tools);
    assert.equal(toolsResult.tools.length, 9);

    // 2. Call observe
    const obsCall = await client.callTool({ name: "computer_use_observe", arguments: {} });
    assert.ok(obsCall.content);
    const obsContent = obsCall.content as any[];
    assert.equal(obsContent.length, 2);
    const textMeta = JSON.parse(obsContent[0].text);
    const cap1 = textMeta.capture_id;
    assert.ok(cap1);

    // 3. Call click action
    const clickCall = await client.callTool({
      name: "computer_use_click",
      arguments: {
        x: 500,
        y: 500,
        button: "left",
        click_count: 1,
        capture_id: cap1,
        topology_version: "top-v1",
        intent: "Click target button in test"
      }
    });

    const clickContent = clickCall.content as any[];
    const clickMeta = JSON.parse(clickContent[0].text);
    assert.equal(clickMeta.status, "dispatched");
    const cap2 = clickMeta.post_action_observation.capture_id;
    assert.ok(cap2);

    // 4. Call type action with press_enter: true adapter
    const typeCall = await client.callTool({
      name: "computer_use_type",
      arguments: {
        text: "search query",
        press_enter: true,
        capture_id: cap2,
        topology_version: "top-v1",
        intent: "Type search query and press enter"
      }
    });
    const typeContent = typeCall.content as any[];
    const typeMeta = JSON.parse(typeContent[0].text);
    assert.equal(typeMeta.status, "dispatched");
    const cap3 = typeMeta.post_action_observation.capture_id;
    assert.ok(cap3);

    // 5. Call scroll action with direction adapter (omitting delta_x / delta_y)
    const scrollCall = await client.callTool({
      name: "computer_use_scroll",
      arguments: {
        x: 500,
        y: 500,
        direction: "down",
        capture_id: cap3,
        topology_version: "top-v1",
        intent: "Scroll down page"
      }
    });
    const scrollContent = scrollCall.content as any[];
    const scrollMeta = JSON.parse(scrollContent[0].text);
    assert.equal(scrollMeta.status, "dispatched");

    await client.close();
    await server.close();
  });

  test("Verifies skill package sync drift between .agents/skills and skills/", () => {
    const rootDir = path.resolve(process.cwd(), "../../");
    const agentSkillDir = path.join(rootDir, ".agents/skills/computer-use");
    const rootSkillDir = path.join(rootDir, "skills/computer-use");

    assert.ok(fs.existsSync(agentSkillDir), `.agents/skills/computer-use must exist`);
    assert.ok(fs.existsSync(rootSkillDir), `skills/computer-use must exist`);

    const agentSkillContent = fs.readFileSync(path.join(agentSkillDir, "SKILL.md"), "utf-8");
    const rootSkillContent = fs.readFileSync(path.join(rootSkillDir, "SKILL.md"), "utf-8");

    assert.equal(agentSkillContent.trim(), rootSkillContent.trim(), "SKILL.md files must be identical");
    assert.ok(fs.existsSync(path.join(rootSkillDir, "references/observe-action-loop.md")));
    assert.ok(fs.existsSync(path.join(rootSkillDir, "references/ax-vs-vision.md")));
  });
});
