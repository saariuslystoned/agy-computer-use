import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createCanaryServer } from "../src/canary.js";
import { MockPeekabooImageClient, PeekabooCanaryResult } from "../src/peekaboo-client.js";

describe("Computer Use Canary MCP Server Test Suite", () => {
  test("Canary inventory contains EXACTLY ONE tool named 'computer_use_canary_screenshot'", async () => {
    const mockClient = new MockPeekabooImageClient();
    const server = createCanaryServer(mockClient);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    const toolsResult = await client.listTools();
    assert.ok(toolsResult.tools);
    assert.equal(toolsResult.tools.length, 1, "Canary server tool inventory must be EXACTLY 1");
    assert.equal(toolsResult.tools[0].name, "computer_use_canary_screenshot");

    const inputSchema = toolsResult.tools[0].inputSchema;
    assert.equal(inputSchema.type, "object");
    assert.deepEqual(inputSchema.properties, {});
    assert.equal(inputSchema.additionalProperties, false);

    await client.close();
    await server.close();
  });

  test("Injected unique image reaches official MCP Client as ImageContent", async () => {
    const uniqueBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
    const customResult: PeekabooCanaryResult = {
      imageBase64: uniqueBase64,
      mimeType: "image/png"
    };

    const mockClient = new MockPeekabooImageClient(customResult);
    const server = createCanaryServer(mockClient);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    const callResult = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.ok(callResult.content);
    const content = callResult.content as any[];
    assert.equal(content.length, 1);

    const imageItem = content[0];
    assert.equal(imageItem.type, "image");
    assert.equal(imageItem.data, uniqueBase64);
    assert.equal(imageItem.mimeType, "image/png");

    await client.close();
    await server.close();
  });

  test("Negative test: Rejects tool call if arguments are passed to canary screenshot", async () => {
    const mockClient = new MockPeekabooImageClient();
    const server = createCanaryServer(mockClient);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    const callResult = await client.callTool({
      name: "computer_use_canary_screenshot",
      arguments: { unexpected_arg: "invalid" }
    });

    assert.equal(callResult.isError, true);
    const textItem = (callResult.content as any[])[0];
    assert.ok(textItem.text.includes("accepts no arguments"));

    await client.close();
    await server.close();
  });

  test("Negative test: Rejects attempt to call unknown tools on canary server", async () => {
    const mockClient = new MockPeekabooImageClient();
    const server = createCanaryServer(mockClient);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    const callResult = await client.callTool({
      name: "computer_use_click",
      arguments: { x: 500, y: 500 }
    });

    assert.equal(callResult.isError, true);
    const textItem = (callResult.content as any[])[0];
    assert.ok(textItem.text.includes("Unknown tool name"));

    await client.close();
    await server.close();
  });

  test("Negative test: Rejects unsupported mimeType from image client", async () => {
    const badClient: MockPeekabooImageClient = new MockPeekabooImageClient({
      imageBase64: "dGVzdA==",
      mimeType: "image/gif" as any
    });

    const server = createCanaryServer(badClient);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    const callResult = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.equal(callResult.isError, true);
    const textItem = (callResult.content as any[])[0];
    assert.ok(textItem.text.includes("Unsupported mimeType"));

    await client.close();
    await server.close();
  });

  test("Negative test: Rejects oversized base64 payload from image client", async () => {
    const hugeBase64 = "A".repeat(23 * 1024 * 1024); // > 22MB base64 cap
    const hugeClient: MockPeekabooImageClient = new MockPeekabooImageClient({
      imageBase64: hugeBase64,
      mimeType: "image/png"
    });

    const server = createCanaryServer(hugeClient);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    const callResult = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.equal(callResult.isError, true);
    const textItem = (callResult.content as any[])[0];
    assert.ok(textItem.text.includes("exceeds 16MB limit"));

    await client.close();
    await server.close();
  });
});
