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
    const toolNames = toolsResult.tools.map((t) => t.name);
    assert.ok(toolNames.includes("computer_use_observe"));
    assert.ok(toolNames.includes("computer_use_click"));

    // 2. Call observe
    const obsCall = await client.callTool({ name: "computer_use_observe", arguments: {} });
    assert.ok(obsCall.content);
    const obsContent = obsCall.content as any[];
    assert.equal(obsContent.length, 2); // Text metadata + ImageContent
    assert.equal(obsContent[0].type, "text");
    assert.equal(obsContent[1].type, "image");
    assert.equal(obsContent[1].mimeType, "image/jpeg");

    const textMeta = JSON.parse(obsContent[0].text);
    const cap1 = textMeta.capture_id;
    assert.ok(cap1);

    // 3. Call click action passing valid parameters
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

    assert.ok(clickCall.content);
    const clickContent = clickCall.content as any[];
    assert.equal(clickContent.length, 2);
    const clickMeta = JSON.parse(clickContent[0].text);
    assert.equal(clickMeta.status, "dispatched");
    assert.ok(clickMeta.post_action_observation);
    const cap2 = clickMeta.post_action_observation.capture_id;
    assert.ok(cap2);
    assert.notEqual(cap1, cap2);

    // 4. Stale click call must return isError: true
    const staleCall = await client.callTool({
      name: "computer_use_click",
      arguments: {
        x: 500,
        y: 500,
        button: "left",
        click_count: 1,
        capture_id: cap1,
        topology_version: "top-v1",
        intent: "Stale click retry"
      }
    });

    assert.equal(staleCall.isError, true);
    const staleContent = staleCall.content as any[];
    const errMeta = JSON.parse(staleContent[0].text);
    assert.equal(errMeta.error.code, "STALE_CAPTURE");

    await client.close();
    await server.close();
  });

  test("Verifies skill package sync drift between .agents/skills and skills/", () => {
    const rootDir = path.resolve(process.cwd(), "../../");
    const agentSkillPath = path.join(rootDir, ".agents/skills/computer-use/SKILL.md");
    const rootSkillPath = path.join(rootDir, "skills/computer-use/SKILL.md");

    assert.ok(fs.existsSync(agentSkillPath), `.agents/skills/computer-use/SKILL.md must exist at ${agentSkillPath}`);
    assert.ok(fs.existsSync(rootSkillPath), `skills/computer-use/SKILL.md must exist at ${rootSkillPath}`);

    const agentSkillContent = fs.readFileSync(agentSkillPath, "utf-8");
    const rootSkillContent = fs.readFileSync(rootSkillPath, "utf-8");

    assert.equal(agentSkillContent.trim(), rootSkillContent.trim(), "Skill packages in .agents/skills/computer-use and skills/computer-use must be identical");
  });
});
