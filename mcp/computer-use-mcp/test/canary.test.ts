import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createCanaryServer } from "../src/canary.js";
import {
  PeekabooImageClientImpl,
  MockPeekabooMcpRawClient,
  VALID_DUMMY_PNG_BASE64,
  VALID_DUMMY_JPEG_BASE64
} from "../src/peekaboo-client.js";

describe("Computer Use Canary MCP Server Protocol Test Suite", () => {
  test("Canary inventory contains EXACTLY ONE tool named 'computer_use_canary_screenshot'", async () => {
    const rawClient = new MockPeekabooMcpRawClient();
    const imageClient = new PeekabooImageClientImpl(rawClient);
    const server = createCanaryServer(imageClient);
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

  test("Happy Path: Valid PNG base64 and magic bytes yields ImageContent and isError is NOT true", async () => {
    const rawClient = new MockPeekabooMcpRawClient({
      content: [
        {
          type: "image",
          data: VALID_DUMMY_PNG_BASE64,
          mimeType: "image/png"
        }
      ]
    });

    const imageClient = new PeekabooImageClientImpl(rawClient);
    const server = createCanaryServer(imageClient);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    const callResult = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.notEqual(callResult.isError, true, "Happy path callTool isError must NOT be true");
    assert.ok(callResult.content);

    const content = callResult.content as any[];
    assert.equal(content.length, 1);

    const imageItem = content[0];
    assert.equal(imageItem.type, "image");
    assert.equal(imageItem.data, VALID_DUMMY_PNG_BASE64);
    assert.equal(imageItem.mimeType, "image/png");

    await client.close();
    await server.close();
  });

  test("Happy Path: Valid JPEG base64 and magic bytes yields ImageContent", async () => {
    const rawClient = new MockPeekabooMcpRawClient({
      content: [
        {
          type: "image",
          data: VALID_DUMMY_JPEG_BASE64,
          mimeType: "image/jpeg"
        }
      ]
    });

    const imageClient = new PeekabooImageClientImpl(rawClient);
    const server = createCanaryServer(imageClient);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    const callResult = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.notEqual(callResult.isError, true);
    const content = callResult.content as any[];
    assert.equal(content[0].mimeType, "image/jpeg");

    await client.close();
    await server.close();
  });

  test("Negative: Rejects raw response with isError: true", async () => {
    const rawClient = new MockPeekabooMcpRawClient({
      isError: true,
      content: [{ type: "text", text: "Peekaboo error" }]
    });

    const server = createCanaryServer(new PeekabooImageClientImpl(rawClient));
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    const res = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.equal(res.isError, true);
    assert.equal((res.content as any[])[0].text, "CANARY_PEEKABOO_ERROR");

    await client.close();
    await server.close();
  });

  test("Negative: Rejects response with missing content items (empty array)", async () => {
    const rawClient = new MockPeekabooMcpRawClient({ content: [] });
    const server = createCanaryServer(new PeekabooImageClientImpl(rawClient));
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    const res = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.equal(res.isError, true);
    assert.equal((res.content as any[])[0].text, "CANARY_CONTENT_INVALID_COUNT");

    await client.close();
    await server.close();
  });

  test("Negative: Rejects response with multiple content items", async () => {
    const rawClient = new MockPeekabooMcpRawClient({
      content: [
        { type: "image", data: VALID_DUMMY_PNG_BASE64, mimeType: "image/png" },
        { type: "image", data: VALID_DUMMY_PNG_BASE64, mimeType: "image/png" }
      ]
    });
    const server = createCanaryServer(new PeekabooImageClientImpl(rawClient));
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    const res = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.equal(res.isError, true);
    assert.equal((res.content as any[])[0].text, "CANARY_CONTENT_INVALID_COUNT");

    await client.close();
    await server.close();
  });

  test("Negative: Rejects response with mixed text + image content items", async () => {
    const rawClient = new MockPeekabooMcpRawClient({
      content: [
        { type: "text", text: "Screen capture result" },
        { type: "image", data: VALID_DUMMY_PNG_BASE64, mimeType: "image/png" }
      ]
    });
    const server = createCanaryServer(new PeekabooImageClientImpl(rawClient));
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    const res = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.equal(res.isError, true);
    assert.equal((res.content as any[])[0].text, "CANARY_CONTENT_INVALID_COUNT");

    await client.close();
    await server.close();
  });

  test("Negative: Rejects unsupported mimeType (image/gif)", async () => {
    const rawClient = new MockPeekabooMcpRawClient({
      content: [
        { type: "image", data: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7", mimeType: "image/gif" }
      ]
    });
    const server = createCanaryServer(new PeekabooImageClientImpl(rawClient));
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    const res = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.equal(res.isError, true);
    assert.equal((res.content as any[])[0].text, "CANARY_UNSUPPORTED_MIME");

    await client.close();
    await server.close();
  });

  test("Negative: Rejects malformed base64 characters", async () => {
    const rawClient = new MockPeekabooMcpRawClient({
      content: [
        { type: "image", data: "!!!not_valid_base64!!!", mimeType: "image/png" }
      ]
    });
    const server = createCanaryServer(new PeekabooImageClientImpl(rawClient));
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    const res = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.equal(res.isError, true);
    assert.equal((res.content as any[])[0].text, "CANARY_MALFORMED_BASE64");

    await client.close();
    await server.close();
  });

  test("Negative: Rejects Magic Bytes mismatch (JPEG header with image/png MIME)", async () => {
    const rawClient = new MockPeekabooMcpRawClient({
      content: [
        { type: "image", data: VALID_DUMMY_JPEG_BASE64, mimeType: "image/png" }
      ]
    });
    const server = createCanaryServer(new PeekabooImageClientImpl(rawClient));
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    const res = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.equal(res.isError, true);
    assert.equal((res.content as any[])[0].text, "CANARY_MAGIC_MISMATCH");

    await client.close();
    await server.close();
  });

  test("Negative: Rejects decoded image payload exceeding 16 MiB", async () => {
    // Generate valid PNG header followed by zeroes > 16 MiB
    const header = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
    const body = Buffer.alloc(16 * 1024 * 1024 + 10);
    header.copy(body, 0);
    const hugeBase64 = body.toString("base64");

    const rawClient = new MockPeekabooMcpRawClient({
      content: [
        { type: "image", data: hugeBase64, mimeType: "image/png" }
      ]
    });
    const server = createCanaryServer(new PeekabooImageClientImpl(rawClient));
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    const res = await client.callTool({ name: "computer_use_canary_screenshot", arguments: {} });
    assert.equal(res.isError, true);
    assert.equal((res.content as any[])[0].text, "CANARY_SIZE_EXCEEDED");

    await client.close();
    await server.close();
  });

  test("Negative: Rejects any arguments passed to computer_use_canary_screenshot", async () => {
    const rawClient = new MockPeekabooMcpRawClient();
    const server = createCanaryServer(new PeekabooImageClientImpl(rawClient));
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "test-canary-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    const res = await client.callTool({
      name: "computer_use_canary_screenshot",
      arguments: { invalid_param: true }
    });
    assert.equal(res.isError, true);
    assert.equal((res.content as any[])[0].text, "CANARY_ARGUMENTS_REJECTED");

    await client.close();
    await server.close();
  });
});
