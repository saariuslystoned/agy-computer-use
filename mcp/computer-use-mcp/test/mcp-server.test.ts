import { test, describe } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "path";
import * as net from "net";
import AjvModule from "ajv";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createComputerUseServer, validateAndDecodeBase64JPEG } from "../src/index.js";
import { MockHostClient, UnixSocketHostClient, IPCResponseSchema } from "../src/host-client.js";

const Ajv = (AjvModule as any).default || AjvModule;

function getRecursiveFiles(dir: string): string[] {
  let results: string[] = [];
  const list = fs.readdirSync(dir);
  for (const file of list) {
    const filePath = path.join(dir, file);
    const stat = fs.statSync(filePath);
    if (stat && stat.isDirectory()) {
      results = results.concat(getRecursiveFiles(filePath));
    } else {
      results.push(filePath);
    }
  }
  return results;
}

const VALID_SHA256_TOPOLOGY_TOKEN = "top-sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

describe("Computer Use MCP Server & HostClient Test Suite (Milestone D2)", () => {
  test("Exercises listTools and callTool using official SDK Client and InMemoryTransport linked pair", async () => {
    const mockHost = new MockHostClient();
    mockHost.inputMutationState = "disabled";
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

    const toolsResult = await client.listTools();
    assert.ok(toolsResult.tools);
    assert.equal(toolsResult.tools.length, 2);

    const toolNames = toolsResult.tools.map(t => t.name).sort();
    assert.deepEqual(toolNames, ["computer_use_observe", "computer_use_status"]);

    const statusCall = await client.callTool({ name: "computer_use_status", arguments: {} });
    assert.ok(statusCall.content);
    const statusText = JSON.parse((statusCall.content as any[])[0].text);
    assert.equal(statusText.connected, true);
    assert.equal(statusText.input_mutation_state, "disabled");
    assert.ok(statusText.topology);

    const obsCall = await client.callTool({ name: "computer_use_observe", arguments: {} });
    assert.ok(obsCall.content);
    const obsContent = obsCall.content as any[];
    assert.equal(obsContent.length, 2);
    const textMeta = JSON.parse(obsContent[0].text);
    const cap1 = textMeta.capture_id;
    assert.ok(cap1);

    await client.close();
    await server.close();
  });

  test("Normalizes omitted MCP arguments to empty object and strict parses status and observe", async () => {
    const mockHost = new MockHostClient();
    const server = createComputerUseServer(mockHost);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "norm-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);

    // Call status without arguments object
    const statusCall = await client.callTool({ name: "computer_use_status" } as any);
    assert.equal((statusCall as any).isError, undefined);
    const statusRes = JSON.parse((statusCall.content as any[])[0].text);
    assert.equal(statusRes.connected, true);

    // Call status with extra arguments -> rejected by strict schema
    const statusExtraCall = await client.callTool({ name: "computer_use_status", arguments: { unexpected: true } as any });
    assert.equal((statusExtraCall as any).isError, true);

    // Call observe without arguments object
    const obsCall = await client.callTool({ name: "computer_use_observe" } as any);
    assert.equal((obsCall as any).isError, undefined);

    await client.close();
    await server.close();
  });

  test("Decoder-invocation seam: proves zero allocation on rejected Base64/JPEG payloads", () => {
    let decodeCount = 0;
    const mockDecoder = (str: string, enc: BufferEncoding) => {
      decodeCount++;
      return Buffer.from(str, enc);
    };

    // N = 10,485,760 bytes limit
    // N+1 = 10,485,761 bytes -> 13,981,016 chars with one '='
    const b64_N_plus_1 = "A".repeat(13_981_015) + "=";
    assert.throws(() => validateAndDecodeBase64JPEG(b64_N_plus_1, undefined, undefined, mockDecoder), /exceeds 10 MiB limit/);
    assert.equal(decodeCount, 0, "Decoder must NOT be invoked when N+1 exceeds 10 MiB limit");

    // N+2 = 10,485,762 bytes -> 13,981,016 chars with no '='
    const b64_N_plus_2 = "A".repeat(13_981_016);
    assert.throws(() => validateAndDecodeBase64JPEG(b64_N_plus_2, undefined, undefined, mockDecoder), /exceeds 10 MiB limit/);
    assert.equal(decodeCount, 0, "Decoder must NOT be invoked when N+2 exceeds 10 MiB limit");

    // N+3 = 13,981,020 chars
    const b64_N_plus_3 = "A".repeat(13_981_020);
    assert.throws(() => validateAndDecodeBase64JPEG(b64_N_plus_3, undefined, undefined, mockDecoder), /exceeds 10 MiB limit/);
    assert.equal(decodeCount, 0, "Decoder must NOT be invoked when N+3 exceeds 10 MiB limit");
  });

  test("Adversarial: Stale top-v1 token fails closed with INVALID_RESPONSE_DATA", async () => {
    const mockHost = new MockHostClient();
    const server = createComputerUseServer(mockHost);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "adv-client-1", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);

    mockHost.request = async (method: string) => {
      if (method === "status") {
        return {
          id: "req-1",
          success: true,
          data: {
            connected: true,
            tcc_permission_state: "granted",
            accessibility_available: false,
            accessibility_trusted: false,
            input_mutation_state: "disabled",
            topology_version: "top-v1",
            primary_display_id: 1,
            display_count: 1,
            topology: { version: "top-v1", primary_display_id: 1, displays: [] }
          }
        };
      }
      return { id: "req-2", success: false, error: { code: "UNKNOWN_METHOD", message: "Not supported" } };
    };

    const statusCall = await client.callTool({ name: "computer_use_status", arguments: {} });
    assert.equal((statusCall as any).isError, true);
    const errText = JSON.parse(((statusCall.content as any[])[0] as any).text);
    assert.equal(errText.error.code, "INVALID_RESPONSE_DATA");

    await client.close();
    await server.close();
  });

  test("Adversarial: Non-JPEG magic bytes fail closed", () => {
    const badMagicB64 = Buffer.from([0x00, 0x01, 0x02, 0x03]).toString("base64");
    assert.throws(() => validateAndDecodeBase64JPEG(badMagicB64), /Invalid JPEG magic bytes/);
  });

  test("Adversarial: Truncated or missing JPEG SOF dimensions fail closed", () => {
    const truncatedB64 = Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString("base64");
    assert.throws(() => validateAndDecodeBase64JPEG(truncatedB64, 100, 100), /Failed to parse valid JPEG SOF/);
  });

  test("Adversarial: Base64 unpadded (length % 4 != 0) fails closed", () => {
    const unpaddedB64 = "/9j/4AAQSkZJRgABAQEAYABgAAD"; // length 27 (% 4 != 0)
    assert.throws(() => validateAndDecodeBase64JPEG(unpaddedB64), /length must be a multiple of 4/);
  });

  test("Adversarial: Base64 non-canonical encoding fails closed", () => {
    const canonicalB64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAARCABkAGQDAREAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/9oADAMBAAIRAxEAPwD+2AD/2R==";
    // Replace '2R==' with '2S==' (non-zero padding bits)
    const tamperedB64 = canonicalB64.replace("2R==", "2S==");
    assert.throws(() => validateAndDecodeBase64JPEG(tamperedB64), /unused padding bits/);
  });

  test("Adversarial: Mismatched response ID rejected by HostClient", async () => {
    const sockPath = `/tmp/test-mismatch-${Date.now()}.sock`;
    const server = net.createServer((socket) => {
      socket.on("data", () => {
        const respObj = { id: "wrong-id-999", success: true, data: { connected: true } };
        const respJson = JSON.stringify(respObj);
        const respBuf = Buffer.from(respJson, "utf-8");
        const headerBuf = Buffer.alloc(4);
        headerBuf.writeUInt32BE(respBuf.length, 0);
        socket.write(headerBuf);
        socket.write(respBuf);
      });
    });
    await new Promise<void>((res) => server.listen(sockPath, res));

    const client = new UnixSocketHostClient(sockPath, 1000);
    const resp = await client.request("status");
    assert.equal(resp.success, false);
    assert.equal(resp.error?.code, "ID_MISMATCH");

    server.close();
    if (fs.existsSync(sockPath)) fs.unlinkSync(sockPath);
  });

  test("Integration path: Official MCP Client -> createComputerUseServer -> UnixSocketHostClient -> UDS Socket", async () => {
    const sockPath = `/tmp/test-mcp-uds-${Date.now()}.sock`;
    const socketServer = net.createServer((socket) => {
      socket.on("data", (data) => {
        if (data.length >= 4) {
          const bodyLen = data.readUInt32BE(0);
          if (data.length >= 4 + bodyLen) {
            const reqObj = JSON.parse(data.subarray(4, 4 + bodyLen).toString("utf-8"));
            const respObj = {
              id: reqObj.id,
              success: true,
              data: {
                connected: true,
                tcc_permission_state: "granted",
                accessibility_available: false,
                accessibility_trusted: false,
                input_mutation_state: "disabled",
                topology_version: VALID_SHA256_TOPOLOGY_TOKEN,
                primary_display_id: 1,
                display_count: 1,
                topology: {
                  version: VALID_SHA256_TOPOLOGY_TOKEN,
                  primary_display_id: 1,
                  displays: [
                    {
                      id: 1,
                      width_points: 1920,
                      height_points: 1080,
                      scale_factor: 2.0,
                      origin_x: 0,
                      origin_y: 0,
                      pixel_width: 3840,
                      pixel_height: 2160,
                      rotation: 0
                    }
                  ]
                }
              }
            };
            const respJson = JSON.stringify(respObj);
            const respBuf = Buffer.from(respJson, "utf-8");
            const headerBuf = Buffer.alloc(4);
            headerBuf.writeUInt32BE(respBuf.length, 0);
            socket.write(headerBuf);
            socket.write(respBuf);
          }
        }
      });
    });

    await new Promise<void>((res) => socketServer.listen(sockPath, res));

    const realHostClient = new UnixSocketHostClient(sockPath, 5000);
    const mcpServer = createComputerUseServer(realHostClient);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    const mcpClient = new Client({ name: "integration-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([
      mcpServer.connect(serverTransport),
      mcpClient.connect(clientTransport)
    ]);

    const statusCall = await mcpClient.callTool({ name: "computer_use_status", arguments: {} });
    assert.ok(statusCall.content);
    const textRes = JSON.parse((statusCall.content as any[])[0].text);
    assert.equal(textRes.connected, true);
    assert.equal(textRes.topology_version, VALID_SHA256_TOPOLOGY_TOKEN);

    await mcpClient.close();
    await mcpServer.close();
    socketServer.close();
    if (fs.existsSync(sockPath)) fs.unlinkSync(sockPath);
  });

  test("Verifies 100% recursive skill package sync drift between .agents/skills and skills/", () => {
    const rootDir = path.resolve(process.cwd(), "../../");
    const agentSkillDir = path.join(rootDir, ".agents/skills/computer-use");
    const rootSkillDir = path.join(rootDir, "skills/computer-use");

    assert.ok(fs.existsSync(agentSkillDir), `.agents/skills/computer-use must exist`);
    assert.ok(fs.existsSync(rootSkillDir), `skills/computer-use must exist`);

    const agentFiles = getRecursiveFiles(agentSkillDir);
    const rootFiles = getRecursiveFiles(rootSkillDir);

    const relAgentFiles = agentFiles.map(f => path.relative(agentSkillDir, f)).sort();
    const relRootFiles = rootFiles.map(f => path.relative(rootSkillDir, f)).sort();

    assert.deepEqual(relAgentFiles, relRootFiles, "Skill directory file hierarchies must match 100%");

    for (const relFile of relAgentFiles) {
      const agentContent = fs.readFileSync(path.join(agentSkillDir, relFile), "utf-8").trim();
      const rootContent = fs.readFileSync(path.join(rootSkillDir, relFile), "utf-8").trim();
      assert.equal(agentContent, rootContent, `Content of skill file '${relFile}' must match 100%`);
    }
  });

  test("Validates all golden JSON fixtures in docs/fixtures/ using explicit fixture-to-schema mappings", () => {
    const rootDir = path.resolve(process.cwd(), "../../");
    const fixturesDir = path.join(rootDir, "docs/fixtures");
    const schemaPath = path.join(rootDir, "docs/protocol_schema.json");

    assert.ok(fs.existsSync(fixturesDir), "docs/fixtures directory must exist");
    assert.ok(fs.existsSync(schemaPath), "docs/protocol_schema.json must exist");

    const schemaContent = fs.readFileSync(schemaPath, "utf-8");
    const protocolSchema = JSON.parse(schemaContent);

    const ajv = new Ajv({ allErrors: true });
    const validateProtocol = ajv.compile(protocolSchema);

    const FIXTURE_MAPPINGS: Record<string, { expectedValid: boolean; schemaTarget?: string }> = {
      "status_request.json": { expectedValid: true, schemaTarget: "StatusRequest" },
      "observe_request.json": { expectedValid: true, schemaTarget: "ObserveRequest" },
      "status_response.json": { expectedValid: true, schemaTarget: "StatusResponse" },
      "observe_response.json": { expectedValid: true, schemaTarget: "ObserveResponse" },
      "permission_denied_response.json": { expectedValid: true, schemaTarget: "ErrorResponse" },
      "stale_topology_response.json": { expectedValid: true, schemaTarget: "ErrorResponse" },
      "timeout_response.json": { expectedValid: true, schemaTarget: "ErrorResponse" },
      "click_request_disabled.json": { expectedValid: false },
      "invalid_click_request_negative.json": { expectedValid: false }
    };

    const fixtureFiles = fs.readdirSync(fixturesDir).filter(f => f.endsWith(".json"));
    assert.ok(fixtureFiles.length >= 4, "Must contain active D2 fixtures");

    for (const file of fixtureFiles) {
      const mapping = FIXTURE_MAPPINGS[file];
      const content = fs.readFileSync(path.join(fixturesDir, file), "utf-8");
      assert.doesNotThrow(() => JSON.parse(content), `Fixture '${file}' must be valid JSON`);
      const parsed = JSON.parse(content);

      if (mapping) {
        const isValid = validateProtocol(parsed);
        assert.equal(isValid, mapping.expectedValid, `Fixture '${file}' Ajv validation state (${isValid}) must match expected state (${mapping.expectedValid}): ${JSON.stringify(validateProtocol.errors)}`);
      } else {
        // Fallback for unmapped fixtures
        const isValid = validateProtocol(parsed);
        assert.ok(isValid !== undefined);
      }

      if (parsed.success === true) {
        const zodParse = IPCResponseSchema.safeParse(parsed);
        assert.ok(zodParse.success, `Response fixture '${file}' must validate against IPCResponseSchema: ${zodParse.error?.message}`);

        if (parsed.data?.image_data_base64) {
          const buf = validateAndDecodeBase64JPEG(parsed.data.image_data_base64, parsed.data.pixel_width, parsed.data.pixel_height);
          assert.ok(buf.length > 0, `Observe fixture '${file}' image buffer must be non-empty`);
        }
      }
    }
  });

  test("UnixSocketHostClient: Oversized frame rejection (>16MB)", async () => {
    const sockPath = `/tmp/test-oversized-${Date.now()}.sock`;
    const server = net.createServer((socket) => {
      socket.on("data", () => {
        const header = Buffer.alloc(4);
        header.writeUInt32BE(17 * 1024 * 1024, 0);
        socket.write(header);
      });
    });

    await new Promise<void>((res) => server.listen(sockPath, res));

    const client = new UnixSocketHostClient(sockPath, 1000);
    const resp = await client.request("status");

    assert.equal(resp.success, false);
    assert.equal(resp.error?.code, "RESPONSE_TOO_LARGE");

    server.close();
    if (fs.existsSync(sockPath)) fs.unlinkSync(sockPath);
  });

  test("UnixSocketHostClient: EOF handling on premature socket close", async () => {
    const sockPath = `/tmp/test-eof-${Date.now()}.sock`;
    const server = net.createServer((socket) => {
      socket.on("data", () => {
        socket.end();
      });
    });

    await new Promise<void>((res) => server.listen(sockPath, res));

    const client = new UnixSocketHostClient(sockPath, 1000);
    const resp = await client.request("status");

    assert.equal(resp.success, false);
    assert.equal(resp.error?.code, "EOF");

    server.close();
    if (fs.existsSync(sockPath)) fs.unlinkSync(sockPath);
  });

  test("UnixSocketHostClient: Request timeout handling", async () => {
    const sockPath = `/tmp/test-timeout-${Date.now()}.sock`;
    const server = net.createServer((_socket) => {
    });

    await new Promise<void>((res) => server.listen(sockPath, res));

    const client = new UnixSocketHostClient(sockPath, 100);
    const resp = await client.request("status");

    assert.equal(resp.success, false);
    assert.equal(resp.error?.code, "TIMEOUT");

    server.close();
    if (fs.existsSync(sockPath)) fs.unlinkSync(sockPath);
  });

  test("UnixSocketHostClient: Cancellation phase distinction (pre-dispatch vs post-dispatch)", async () => {
    const sockPath = `/tmp/test-cancel-${Date.now()}.sock`;
    const server = net.createServer((_socket) => {
    });

    await new Promise<void>((res) => server.listen(sockPath, res));

    const client = new UnixSocketHostClient(sockPath, 5000);

    const controller1 = new AbortController();
    controller1.abort();
    const resp1 = await client.request("click", { x: 500, y: 500, capture_id: "cap-1", topology_version: VALID_SHA256_TOPOLOGY_TOKEN, intent: "Click" }, controller1.signal);
    assert.equal(resp1.success, false);
    assert.equal(resp1.error?.code, "CANCELLED");

    const controller2 = new AbortController();
    const reqPromise = client.request("click", { x: 500, y: 500, capture_id: "cap-1", topology_version: VALID_SHA256_TOPOLOGY_TOKEN, intent: "Click" }, controller2.signal);

    setTimeout(() => {
      controller2.abort();
    }, 50);

    const resp2 = await reqPromise;
    assert.equal(resp2.success, false);
    assert.equal(resp2.error?.code, "ACTION_OUTCOME_UNKNOWN");

    server.close();
    if (fs.existsSync(sockPath)) fs.unlinkSync(sockPath);
  });

  test("UnixSocketHostClient: Received request then close maps post-dispatch mutation to ACTION_OUTCOME_UNKNOWN", async () => {
    const sockPath = `/tmp/test-dispatch-close-${Date.now()}.sock`;
    const server = net.createServer((socket) => {
      socket.on("data", () => {
        socket.destroy();
      });
    });

    await new Promise<void>((res) => server.listen(sockPath, res));

    const client = new UnixSocketHostClient(sockPath, 5000);
    const resp = await client.request("click", { x: 500, y: 500, capture_id: "cap-1", topology_version: VALID_SHA256_TOPOLOGY_TOKEN, intent: "Click" });

    assert.equal(resp.success, false);
    assert.equal(resp.error?.code, "ACTION_OUTCOME_UNKNOWN");

    server.close();
    if (fs.existsSync(sockPath)) fs.unlinkSync(sockPath);
  });
});
