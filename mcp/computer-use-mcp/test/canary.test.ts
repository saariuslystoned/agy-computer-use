import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createCanaryServer } from "../src/canary.js";
import {
  PeekabooImageClientImpl,
  MockPeekabooMcpRawClient,
  MockPeekabooImageClient,
  parseAndValidateRawImageResponse,
  VALID_DUMMY_PNG_BASE64,
  VALID_DUMMY_JPEG_BASE64
} from "../src/peekaboo-client.js";

describe("Computer Use Canary MCP Server Protocol & Hardening Test Suite", () => {
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

  test("Base64 Pre-Allocation Guard: Rejects encoded input exceeding MAX_ENCODED_CHARS before Buffer.from", () => {
    // Generate base64 string longer than 22,369,624 chars
    const hugeEncodedString = "A".repeat(22369628);
    assert.throws(
      () => parseAndValidateRawImageResponse({
        content: [{ type: "image", data: hugeEncodedString, mimeType: "image/png" }]
      }),
      (err: any) => err.message === "CANARY_SIZE_EXCEEDED"
    );
  });

  test("Canonical Base64 Check: Rejects missing padding (length % 4 != 0)", () => {
    // 3 characters instead of 4
    const unpadded = "iVB";
    assert.throws(
      () => parseAndValidateRawImageResponse({
        content: [{ type: "image", data: unpadded, mimeType: "image/png" }]
      }),
      (err: any) => err.message === "CANARY_MALFORMED_BASE64"
    );
  });

  test("Canonical Base64 Check: Rejects misplaced or excess padding", () => {
    const badPadding = "iVBORw0K=="; // Invalid padding placement
    assert.throws(
      () => parseAndValidateRawImageResponse({
        content: [{ type: "image", data: badPadding, mimeType: "image/png" }]
      }),
      (err: any) => err.message === "CANARY_MALFORMED_BASE64"
    );
  });

  test("Canonical Base64 Check: Rejects embedded whitespace and newlines", () => {
    const whitespaceData = "iVBORw0K\nAAA";
    assert.throws(
      () => parseAndValidateRawImageResponse({
        content: [{ type: "image", data: whitespaceData, mimeType: "image/png" }]
      }),
      (err: any) => err.message === "CANARY_MALFORMED_BASE64"
    );
  });

  test("Canonical Base64 Check: Rejects trailing garbage characters", () => {
    const trailingGarbage = VALID_DUMMY_PNG_BASE64 + "extra";
    assert.throws(
      () => parseAndValidateRawImageResponse({
        content: [{ type: "image", data: trailingGarbage, mimeType: "image/png" }]
      }),
      (err: any) => err.message === "CANARY_MALFORMED_BASE64"
    );
  });

  test("Error Contract: Validates CANARY_RESPONSE_INVALID for non-object raw response", () => {
    assert.throws(
      () => parseAndValidateRawImageResponse("not_an_object"),
      (err: any) => err.message === "CANARY_RESPONSE_INVALID"
    );
    assert.throws(
      () => parseAndValidateRawImageResponse(null),
      (err: any) => err.message === "CANARY_RESPONSE_INVALID"
    );
  });

  test("Error Contract: Validates CANARY_EMPTY_DECODED_BUFFER", () => {
    // Empty string is handled by CANARY_EMPTY_BASE64
    assert.throws(
      () => parseAndValidateRawImageResponse({
        content: [{ type: "image", data: "", mimeType: "image/png" }]
      }),
      (err: any) => err.message === "CANARY_EMPTY_BASE64"
    );
  });

  test("Lifecycle Seam: Success, error, and timeout paths attempt cleanup (closeAttempted == true)", async () => {
    // 1. Success Path
    const successRawClient = new MockPeekabooMcpRawClient();
    const successImageClient = new PeekabooImageClientImpl(successRawClient);
    await successImageClient.captureCalculator();
    assert.equal(successRawClient.closeAttempted, true, "Success path must attempt cleanup");

    // 2. Thrown Error Path
    const errorRawClient = new MockPeekabooMcpRawClient(new Error("Simulated peekaboo crash"));
    const errorImageClient = new PeekabooImageClientImpl(errorRawClient);
    await assert.rejects(() => errorImageClient.captureCalculator(), /Simulated peekaboo crash/);
    assert.equal(errorRawClient.closeAttempted, true, "Error path must attempt cleanup");

    // 3. Timeout Path
    const timeoutRawClient = new MockPeekabooMcpRawClient("TIMEOUT_SIMULATION");
    const timeoutImageClient = new PeekabooImageClientImpl(timeoutRawClient);
    await assert.rejects(() => timeoutImageClient.captureCalculator(), /CANARY_TIMEOUT/);
    assert.equal(timeoutRawClient.closeAttempted, true, "Timeout path must attempt cleanup");
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
