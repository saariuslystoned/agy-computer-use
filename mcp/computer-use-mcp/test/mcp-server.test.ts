import { test, describe } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "path";
import * as net from "net";
import * as crypto from "crypto";
import AjvModule from "ajv";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
import { createComputerUseServer, validateAndDecodeBase64JPEG, parseJPEGDimensions } from "../src/index.js";
import { validatePixelDimensions, AXTreeDataSchema, DragInputSchema } from "../src/schemas.js";
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
    assert.equal(toolsResult.tools.length, 9);

    const toolNames = toolsResult.tools.map(t => t.name).sort();
    assert.deepEqual(toolNames, [
      "computer_use_ax_tree",
      "computer_use_click",
      "computer_use_drag",
      "computer_use_move",
      "computer_use_observe",
      "computer_use_scroll",
      "computer_use_shortcut",
      "computer_use_status",
      "computer_use_type"
    ]);

    const statusCall = await client.callTool({ name: "computer_use_status", arguments: {} });
    assert.ok(statusCall.content);
    const statusText = JSON.parse((statusCall.content as any[])[0].text);
    assert.equal(statusText.connected, true);
    assert.equal(statusText.input_mutation_state, "disabled");
    assert.ok(statusText.topology);

    const obsCall = await client.callTool({ name: "computer_use_observe", arguments: {} });
    assert.ok(obsCall.content);
    const obsContent = obsCall.content as any[];
    assert.equal(obsContent.length, 2, "Must return exactly 2 ordered content blocks");

    // Block 1: Text metadata without base64 string
    assert.equal(obsContent[0].type, "text");
    const textMeta = JSON.parse(obsContent[0].text);
    assert.ok(textMeta.capture_id);
    assert.equal(textMeta.image_format, "jpeg");
    assert.equal(textMeta.image_data_base64, undefined, "Text metadata block MUST NOT contain image_data_base64");
    assert.ok(textMeta.image_byte_length > 0);
    assert.match(textMeta.image_sha256, /^[0-9a-f]{64}$/);

    // Block 2: Image payload
    assert.equal(obsContent[1].type, "image");
    assert.equal(obsContent[1].mimeType, "image/jpeg");
    assert.ok(obsContent[1].data);

    // Verify byte length, SHA-256 digest, and magic bytes / dimensions match native metadata
    const imgBuf = Buffer.from(obsContent[1].data, "base64");
    assert.equal(imgBuf.length, textMeta.image_byte_length);
    const recomputedSha = crypto.createHash("sha256").update(imgBuf).digest("hex");
    assert.equal(recomputedSha, textMeta.image_sha256);
    assert.equal(imgBuf[0], 0xff);
    assert.equal(imgBuf[1], 0xd8);
    assert.equal(imgBuf[2], 0xff);
    const dims = parseJPEGDimensions(imgBuf);
    assert.ok(dims);
    assert.equal(dims.width, textMeta.pixel_width);
    assert.equal(dims.height, textMeta.pixel_height);

    await client.close();
    await server.close();
  });

  test("Executes observe -> click -> observe -> type -> observe -> shortcut -> observe lease chain", async () => {
    const mockHost = new MockHostClient();
    mockHost.inputMutationState = "enabled";
    const server = createComputerUseServer(mockHost);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "chain-client", version: "1.0.0" }, { capabilities: {} });

    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);

    const obs1 = await client.callTool({ name: "computer_use_observe", arguments: {} });
    const meta1 = JSON.parse((obs1.content as any[])[0].text);
    assert.ok(meta1.capture_id);
    assert.ok(meta1.topology_version);

    const clickRes = await client.callTool({
      name: "computer_use_click",
      arguments: {
        capture_id: meta1.capture_id,
        topology_version: meta1.topology_version,
        x: 500,
        y: 300,
        button: "left",
        click_count: 1,
        intent: "Click target button"
      }
    });
    assert.equal(clickRes.isError, undefined);
    const clickData = JSON.parse((clickRes.content as any[])[0].text);
    assert.equal(clickData.status, "dispatched");

    const obs2 = await client.callTool({ name: "computer_use_observe", arguments: {} });
    const meta2 = JSON.parse((obs2.content as any[])[0].text);

    const typeRes = await client.callTool({
      name: "computer_use_type",
      arguments: {
        capture_id: meta2.capture_id,
        topology_version: meta2.topology_version,
        text: "Hello World",
        press_enter: true,
        intent: "Type hello text"
      }
    });
    assert.equal(typeRes.isError, undefined);
    const typeData = JSON.parse((typeRes.content as any[])[0].text);
    assert.equal(typeData.status, "dispatched");

    const obs3 = await client.callTool({ name: "computer_use_observe", arguments: {} });
    const meta3 = JSON.parse((obs3.content as any[])[0].text);

    const scRes = await client.callTool({
      name: "computer_use_shortcut",
      arguments: {
        capture_id: meta3.capture_id,
        topology_version: meta3.topology_version,
        keys: ["cmd", "tab"],
        intent: "Switch app window"
      }
    });
    assert.equal(scRes.isError, undefined);
    const scData = JSON.parse((scRes.content as any[])[0].text);
    assert.equal(scData.status, "dispatched");

    const obs4 = await client.callTool({ name: "computer_use_observe", arguments: {} });
    const meta4 = JSON.parse((obs4.content as any[])[0].text);
    assert.ok(meta4.capture_id);

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
    assert.throws(() => validateAndDecodeBase64JPEG(b64_N_plus_1, undefined, undefined, undefined, undefined, mockDecoder), /exceeds 10 MiB limit/);
    assert.equal(decodeCount, 0, "Decoder must NOT be invoked when N+1 exceeds 10 MiB limit");

    // N+2 = 10,485,762 bytes -> 13,981,016 chars with no '='
    const b64_N_plus_2 = "A".repeat(13_981_016);
    assert.throws(() => validateAndDecodeBase64JPEG(b64_N_plus_2, undefined, undefined, undefined, undefined, mockDecoder), /exceeds 10 MiB limit/);
    assert.equal(decodeCount, 0, "Decoder must NOT be invoked when N+2 exceeds 10 MiB limit");

    // N+3 = 13,981,020 chars
    const b64_N_plus_3 = "A".repeat(13_981_020);
    assert.throws(() => validateAndDecodeBase64JPEG(b64_N_plus_3, undefined, undefined, undefined, undefined, mockDecoder), /exceeds 10 MiB limit/);
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

  test("Decoder-invocation seam: accepts exact N=10,485,760 byte boundary", () => {
    let decodeCount = 0;
    const mockDecoder = (str: string, enc: BufferEncoding) => {
      decodeCount++;
      // Return minimal valid JPEG buffer for test seam
      return Buffer.from([0xff, 0xd8, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x0a, 0x00, 0x0a, 0x01, 0x01, 0x11, 0x00, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0xff, 0xd9]);
    };
    // 10,485,760 bytes in Base64 (13,981,016 chars with '==' padding)
    const b64_N = "A".repeat(13_981_014) + "==";
    assert.doesNotThrow(() => validateAndDecodeBase64JPEG(b64_N, 10, 10, undefined, undefined, mockDecoder));
    assert.equal(decodeCount, 1);
  });

  test("Adversarial: SOS before SOF in JPEG fails closed", () => {
    // 0xFFD8 (SOI), 0xFFDA (SOS), 0xFFC0 (SOF0), 0xFFD9 (EOI)
    const sosBeforeSof = Buffer.from([0xff, 0xd8, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x0a, 0x00, 0x0a, 0x01, 0x01, 0x11, 0x00, 0xff, 0xd9]);
    assert.equal(parseJPEGDimensions(sosBeforeSof), null);
  });

  test("Adversarial: Invalid SOF or SOS segment lengths in JPEG fail closed", () => {
    // Bad SOF length (should be 11, set to 10)
    const badSofLen = Buffer.from([0xff, 0xd8, 0xff, 0xc0, 0x00, 0x0a, 0x08, 0x00, 0x0a, 0x00, 0x0a, 0x01, 0x01, 0x11, 0x00, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0xff, 0xd9]);
    assert.equal(parseJPEGDimensions(badSofLen), null);
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
      "ax_tree_request.json": { expectedValid: true, schemaTarget: "AxTreeRequest" },
      "ax_tree_response.json": { expectedValid: true, schemaTarget: "AxTreeResponse" },
      "move_request.json": { expectedValid: true, schemaTarget: "MoveRequest" },
      "scroll_request.json": { expectedValid: true, schemaTarget: "ScrollRequest" },
      "drag_request.json": { expectedValid: true, schemaTarget: "DragRequest" },
      "status_response.json": { expectedValid: true, schemaTarget: "StatusResponse" },
      "observe_response.json": { expectedValid: true, schemaTarget: "ObserveResponse" },
      "permission_denied_response.json": { expectedValid: true, schemaTarget: "ErrorResponse" },
      "stale_topology_response.json": { expectedValid: true, schemaTarget: "ErrorResponse" },
      "timeout_response.json": { expectedValid: true, schemaTarget: "ErrorResponse" },
      "ax_tree_unreachable_response.json": { expectedValid: true, schemaTarget: "ErrorResponse" },
      "click_request_disabled.json": { expectedValid: true, schemaTarget: "ClickRequest" },
      "invalid_click_request_negative.json": { expectedValid: false },
      "invalid_method_request_negative.json": { expectedValid: false },
      "canonical_jpeg_mutations.json": { expectedValid: false }
    };

    const fixtureFiles = fs.readdirSync(fixturesDir).filter(f => f.endsWith(".json"));
    assert.ok(fixtureFiles.length >= 5, "Must contain active protocol fixtures");

    for (const file of fixtureFiles) {
      const mapping = FIXTURE_MAPPINGS[file];
      assert.ok(mapping, `Fixture '${file}' must have an explicit mapping in FIXTURE_MAPPINGS`);
      const content = fs.readFileSync(path.join(fixturesDir, file), "utf-8");
      assert.doesNotThrow(() => JSON.parse(content), `Fixture '${file}' must be valid JSON`);
      const parsed = JSON.parse(content);

      let isValid: boolean;
      if (mapping.schemaTarget) {
        const subValidator = ajv.getSchema(`#/definitions/${mapping.schemaTarget}`);
        isValid = subValidator ? (subValidator(parsed) as boolean) : (validateProtocol(parsed) as boolean);
      } else {
        isValid = validateProtocol(parsed) as boolean;
      }

      assert.equal(isValid, mapping.expectedValid, `Fixture '${file}' Ajv validation state (${isValid}) must match expected state (${mapping.expectedValid}): ${JSON.stringify(validateProtocol.errors)}`);

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

  test("Section 4: Canonical JPEG mutation table parity and byte identity", () => {
    function decodeHexStrict(hexStr: string): Buffer {
      // I4 — No trimming; validate original string directly
      if (!/^[0-9a-f]+$/.test(hexStr)) {
        throw new Error("Hex string must contain lowercase hex characters only");
      }
      if (hexStr.length === 0 || hexStr.length % 2 !== 0) {
        throw new Error("Hex string must have even non-zero length");
      }
      const buf = Buffer.from(hexStr, "hex");
      if (buf.toString("hex") !== hexStr) {
        throw new Error("Hex encode-back roundtrip mismatch");
      }
      return buf;
    }

    // Direct negative decoder assertions
    assert.throws(() => decodeHexStrict("0"), /even non-zero length/);
    assert.throws(() => decodeHexStrict("gg"), /lowercase hex characters only/);
    assert.throws(() => decodeHexStrict("AA"), /lowercase hex characters only/);
    // I4 — Whitespace negative assertions
    assert.throws(() => decodeHexStrict(" 00"), /lowercase hex characters only/);
    assert.throws(() => decodeHexStrict("00\n"), /lowercase hex characters only/);

    const rootDir = path.resolve(process.cwd(), "../../");
    const mcpPkgDir = process.cwd();
    const docFixturePath = path.join(rootDir, "docs/fixtures/golden_progressive.jpg");
    const mcpFixturePath = path.join(mcpPkgDir, "test/fixtures/golden_progressive.jpg");

    assert.ok(fs.existsSync(docFixturePath), "docs/fixtures/golden_progressive.jpg must exist");
    assert.ok(fs.existsSync(mcpFixturePath), "test/fixtures/golden_progressive.jpg must exist");

    const docBuf = fs.readFileSync(docFixturePath);
    const mcpBuf = fs.readFileSync(mcpFixturePath);

    // I5 — Explicit golden size anchors
    assert.equal(docBuf.length, 534, "docs/fixtures/golden_progressive.jpg must be exactly 534 bytes");
    assert.equal(mcpBuf.length, 534, "test/fixtures/golden_progressive.jpg must be exactly 534 bytes");

    const docHash = crypto.createHash("sha256").update(docBuf).digest("hex");
    const mcpHash = crypto.createHash("sha256").update(mcpBuf).digest("hex");

    assert.equal(docHash, mcpHash, "Both golden_progressive.jpg fixture files must be byte-identical SHA-256");
    assert.equal(docHash, "afc2917f7357e4f883aa4105aa90aa4e5cb0b4df83365eb00a4142cd1980f24d");

    const canonicalTablePath = path.join(rootDir, "docs/fixtures/canonical_jpeg_mutations.json");
    const table: Array<{ id: number; name: string; expectedResult: string; expectedWidth?: number; expectedHeight?: number; sha256: string; hex: string }> =
      JSON.parse(fs.readFileSync(canonicalTablePath, "utf-8"));

    assert.equal(table.length, 16, "Canonical JPEG mutation table must contain exactly 16 rows");

    const seenIds = new Set<number>();
    for (let idx = 0; idx < table.length; idx++) {
      const row = table[idx];
      assert.equal(row.id, idx + 1, "Ordered IDs must equal 1..16");
      seenIds.add(row.id);
      assert.ok(row.expectedResult === "accept" || row.expectedResult === "reject", "expectedResult must be accept or reject");

      if (row.expectedResult === "accept") {
        assert.ok(row.expectedWidth !== undefined, `Accepted row ${row.id} must have expectedWidth`);
        assert.ok(row.expectedHeight !== undefined, `Accepted row ${row.id} must have expectedHeight`);
      } else {
        assert.equal(row.expectedWidth, undefined, `Rejected row ${row.id} must not have expectedWidth`);
        assert.equal(row.expectedHeight, undefined, `Rejected row ${row.id} must not have expectedHeight`);
      }

      const mutBuf = decodeHexStrict(row.hex);

      if (row.id === 1) {
        assert.equal(row.name, "Identity");
        assert.equal(row.expectedResult, "accept");
        assert.equal(row.expectedWidth, 10);
        assert.equal(row.expectedHeight, 10);
        assert.equal(row.sha256, "afc2917f7357e4f883aa4105aa90aa4e5cb0b4df83365eb00a4142cd1980f24d");
        assert.ok(mutBuf.equals(docBuf), "Row 1 decoded bytes must be byte-identical to golden fixture");
      }

      const mutHash = crypto.createHash("sha256").update(mutBuf).digest("hex");
      assert.equal(mutHash, row.sha256, `SHA-256 mismatch for row ${row.id} (${row.name})`);

      const res = parseJPEGDimensions(mutBuf);
      if (row.expectedResult === "accept") {
        assert.ok(res !== null, `Row ${row.id} (${row.name}) must be accepted`);
        assert.equal(res?.width, row.expectedWidth, `Row ${row.id} width mismatch`);
        assert.equal(res?.height, row.expectedHeight, `Row ${row.id} height mismatch`);
      } else {
        assert.equal(res, null, `Row ${row.id} (${row.name}) must be rejected`);
      }
    }
    assert.equal(seenIds.size, 16, "Unique ID set size must be 16");
  });

  test("Section 5: Dimension rejection bounds (0, negative, overflow, exact 64M, exact 64M+1)", () => {
    // Zero width
    const zeroWidthBuf = Buffer.from([
      0xff, 0xd8, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x64, 0x00, 0x00, 0x01, 0x01, 0x11, 0x00, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0xff, 0xd9
    ]);
    assert.equal(parseJPEGDimensions(zeroWidthBuf), null);

    // Exact 64M+1 (5213x12277 = 64,000,001)
    const exact64MPlus1Buf = Buffer.from([
      0xff, 0xd8, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x14, 0x5d, 0x2f, 0xf5, 0x01, 0x01, 0x11, 0x00, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0xff, 0xd9
    ]);
    assert.equal(parseJPEGDimensions(exact64MPlus1Buf), null);

    // Exact 64M (8000x8000 = 64,000,000)
    const exact64MBuf = Buffer.from([
      0xff, 0xd8, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x1f, 0x40, 0x1f, 0x40, 0x01, 0x01, 0x11, 0x00, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0xff, 0xd9
    ]);
    assert.deepEqual(parseJPEGDimensions(exact64MBuf), { width: 8000, height: 8000 });

    assert.equal(validatePixelDimensions(0, 100), false, "Zero width must be rejected");
    assert.equal(validatePixelDimensions(-10, 100), false, "Negative width must be rejected");
    assert.equal(validatePixelDimensions(100, -5), false, "Negative height must be rejected");
    assert.equal(validatePixelDimensions(1e12, 1e12), false, "Unsafe integer overflow must be rejected");
    assert.equal(validatePixelDimensions(5213, 12277), false, "Exact 64M+1 (64,000,001) must be rejected");
    assert.equal(validatePixelDimensions(8000, 8000), true, "Exact 64M (64,000,000) must be accepted");
  });

  test("Deterministic Configured Launcher: Stdio transport launcher under minimal ambient PATH and missing toolchain negative discriminator", async () => {
    let curDir = __dirname;
    let rootDir = "";
    while (curDir !== path.dirname(curDir)) {
      if (fs.existsSync(path.join(curDir, ".agents/mcp_config.json"))) {
        rootDir = curDir;
        break;
      }
      curDir = path.dirname(curDir);
    }
    if (!rootDir) {
      throw new Error(`Could not find repo root from ${__dirname}`);
    }

    const mcpConfigPath = path.join(rootDir, ".agents/mcp_config.json");
    const mcpConfig = JSON.parse(fs.readFileSync(mcpConfigPath, "utf-8"));
    const prodServer = mcpConfig.mcpServers["computer-use"];

    assert.equal(prodServer.command, "./bin/mcp-server.sh", "Configured launcher command must be ./bin/mcp-server.sh");
    assert.deepEqual(prodServer.args, []);
    assert.equal(prodServer.cwd, ".");

    const nodeBinDir = path.dirname(process.execPath);
    let pnpmBinDir = nodeBinDir;
    try {
      const pnpmPath = execSync("command -v pnpm || true", { encoding: "utf-8" }).trim();
      if (pnpmPath) {
        pnpmBinDir = path.dirname(pnpmPath);
      }
    } catch {}

    const pathDirs = Array.from(new Set([nodeBinDir, pnpmBinDir, "/usr/bin", "/bin"])).join(":");

    const minimalPathEnv = {
      PATH: pathDirs,
      HOME: process.env.HOME || "",
      USER: process.env.USER || "",
      SHELL: process.env.SHELL || "/bin/sh",
      TEST_FORCE_MISSING_MISE: "1"
    };

    const transport = new StdioClientTransport({
      command: prodServer.command,
      args: prodServer.args,
      cwd: rootDir,
      env: minimalPathEnv
    });

    const client = new Client(
      { name: "launcher-test-client", version: "1.0.0" },
      { capabilities: {} }
    );

    await client.connect(transport);

    const toolsResult = await client.listTools();
    assert.ok(toolsResult.tools);
    assert.equal(toolsResult.tools.length, 9);
    const toolNames = toolsResult.tools.map(t => t.name).sort();
    assert.deepEqual(toolNames, [
      "computer_use_ax_tree",
      "computer_use_click",
      "computer_use_drag",
      "computer_use_move",
      "computer_use_observe",
      "computer_use_scroll",
      "computer_use_shortcut",
      "computer_use_status",
      "computer_use_type"
    ]);

    await client.close();

    const launcherAbsPath = path.join(rootDir, prodServer.command);
    let output = "";
    let exitCode = 0;
    try {
      execSync(`"${launcherAbsPath}"`, {
        cwd: rootDir,
        env: { PATH: "/nonexistent_dir_12345", HOME: "/nonexistent_home_12345", TEST_FORCE_MISSING_MISE: "1" },
        encoding: "utf-8",
        stdio: ["ignore", "pipe", "pipe"]
      });
    } catch (err: any) {
      exitCode = err.status || 1;
      output = (err.stderr || "") + "\n" + (err.stdout || "");
    }

    assert.notEqual(exitCode, 0, "Missing toolchain launcher execution must exit nonzero");
    assert.match(output, /\[mcp-server-launcher\] ERROR:/, "Missing toolchain launcher output must contain diagnostic error");

    // Mismatched ambient version discriminator test
    const tmpDir = fs.mkdtempSync(path.join(rootDir, "mcp/computer-use-mcp/test/fixtures/tmp_stub_") + Math.random().toString(36).substring(2));
    const stubNode = path.join(tmpDir, "node");
    fs.writeFileSync(stubNode, "#!/bin/sh\nif [ \"$1\" = \"-v\" ]; then echo 'v26.0.0'; exit 0; fi\nexit 1\n", { mode: 0o755 });

    let misOutput = "";
    let misExitCode = 0;
    try {
      execSync(`"${launcherAbsPath}"`, {
        cwd: rootDir,
        env: { PATH: `${tmpDir}:/usr/bin:/bin`, HOME: tmpDir, TEST_FORCE_MISSING_MISE: "1" },
        encoding: "utf-8",
        stdio: ["ignore", "pipe", "pipe"]
      });
    } catch (err: any) {
      misExitCode = err.status || 1;
      misOutput = (err.stderr || "") + "\n" + (err.stdout || "");
    } finally {
      try {
        fs.rmSync(tmpDir, { recursive: true, force: true });
      } catch {}
    }

    assert.notEqual(misExitCode, 0, "Mismatched version launcher execution must exit nonzero");
    assert.match(misOutput, /does not match pinned versions/, "Mismatched version launcher output must contain version diagnostic error");
  });

  test("M9-ACCESSIBILITY-TRUTH: Trusted CGEvent input works when AX tree inspection is unavailable (accessibility_trusted=true, ax_tree_inspection_available=false)", async () => {
    const mockHost = new MockHostClient();
    mockHost.tccState = "granted";
    mockHost.axTrusted = true;
    mockHost.axAvailable = false;
    mockHost.inputMutationState = "enabled";

    const server = createComputerUseServer(mockHost);
    const client = new Client({ name: "test-client", version: "1.0.0" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    const statusCall = await client.callTool({ name: "computer_use_status", arguments: {} });
    assert.equal((statusCall as any).isError, undefined);
    const statusData = JSON.parse(((statusCall.content as any[])[0] as any).text);
    assert.equal(statusData.accessibility_trusted, true, "accessibility_trusted must be true when process has OS trust");
    assert.equal(statusData.accessibility_available, false, "accessibility_available reflects axEngine availability");
    assert.equal(statusData.ax_tree_inspection_available, false, "ax_tree_inspection_available reflects axEngine availability");
    assert.equal(statusData.input_mutation_state, "enabled", "input_mutation_state must be enabled");

    await client.close();
    await server.close();
  });

  test("M9-PID-NORMALIZATION: Tests status response with optional pid present and legacy no-pid fallback", async () => {
    const mockHost = new MockHostClient();
    mockHost.tccState = "granted";
    mockHost.axTrusted = true;
    mockHost.inputMutationState = "enabled";

    const server = createComputerUseServer(mockHost);
    const client = new Client({ name: "test-client", version: "1.0.0" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    const statusCall1 = await client.callTool({ name: "computer_use_status", arguments: {} });
    assert.equal((statusCall1 as any).isError, undefined);
    const data1 = JSON.parse(((statusCall1.content as any[])[0] as any).text);
    assert.equal(data1.pid, undefined, "Legacy status response without pid passes schema validation");

    await client.close();
    await server.close();

    const mockHostWithPid = new MockHostClient();
    mockHostWithPid.tccState = "granted";
    mockHostWithPid.axTrusted = true;
    mockHostWithPid.inputMutationState = "enabled";

    const origRequest = mockHostWithPid.request.bind(mockHostWithPid);
    mockHostWithPid.request = async (method: string, params?: Record<string, any>, signal?: AbortSignal) => {
      const resp = await origRequest(method, params, signal);
      if (method === "status" && resp.success && resp.data) {
        resp.data.pid = 99887;
      }
      return resp;
    };

    const server2 = createComputerUseServer(mockHostWithPid);
    const client2 = new Client({ name: "test-client", version: "1.0.0" });
    const [ct2, st2] = InMemoryTransport.createLinkedPair();

    await Promise.all([
      server2.connect(st2),
      client2.connect(ct2)
    ]);

    const statusCall2 = await client2.callTool({ name: "computer_use_status", arguments: {} });
    assert.equal((statusCall2 as any).isError, undefined);
    const data2 = JSON.parse(((statusCall2.content as any[])[0] as any).text);
    assert.equal(data2.pid, 99887, "Status response with positive integer pid passes schema validation");

    await client2.close();
    await server2.close();
  });

  test("M10-TOOL-SURFACE: Tests computer_use_ax_tree, computer_use_move, computer_use_scroll, computer_use_drag validation and forwarding", async () => {
    const mockHost = new MockHostClient();
    mockHost.tccState = "granted";
    mockHost.axTrusted = true;
    mockHost.inputMutationState = "enabled";
    const server = createComputerUseServer(mockHost);

    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client(
      { name: "m10-test-client", version: "1.0.0" },
      { capabilities: {} }
    );

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    // 1. computer_use_ax_tree
    const axCall = await client.callTool({
      name: "computer_use_ax_tree",
      arguments: { app_id: "com.apple.calculator", max_depth: 5 }
    });
    assert.equal((axCall as any).isError, undefined);
    const axData = JSON.parse(((axCall.content as any[])[0] as any).text);
    assert.equal(axData.target_app.bundle_id, "com.apple.calculator");
    assert.ok(axData.tree);

    // Observe to get valid capture_id
    const obsCall = await client.callTool({ name: "computer_use_observe", arguments: {} });
    const obsMeta = JSON.parse(((obsCall.content as any[])[0] as any).text);
    const capId = obsMeta.capture_id;
    const topVer = obsMeta.topology_version;

    // 2. computer_use_move
    const moveCall = await client.callTool({
      name: "computer_use_move",
      arguments: {
        capture_id: capId,
        topology_version: topVer,
        x: 500,
        y: 500,
        intent: "Move cursor to center"
      }
    });
    assert.equal((moveCall as any).isError, undefined);

    // 3. computer_use_scroll
    const obsCall2 = await client.callTool({ name: "computer_use_observe", arguments: {} });
    const obsMeta2 = JSON.parse(((obsCall2.content as any[])[0] as any).text);
    const scrollCall = await client.callTool({
      name: "computer_use_scroll",
      arguments: {
        capture_id: obsMeta2.capture_id,
        topology_version: obsMeta2.topology_version,
        x: 500,
        y: 500,
        delta_x: 0,
        delta_y: -100,
        intent: "Scroll down"
      }
    });
    assert.equal((scrollCall as any).isError, undefined);

    // 4. Invalid scroll with zero deltas
    const obsCall3 = await client.callTool({ name: "computer_use_observe", arguments: {} });
    const obsMeta3 = JSON.parse(((obsCall3.content as any[])[0] as any).text);
    const invalidScrollCall = await client.callTool({
      name: "computer_use_scroll",
      arguments: {
        capture_id: obsMeta3.capture_id,
        topology_version: obsMeta3.topology_version,
        x: 500,
        y: 500,
        delta_x: 0,
        delta_y: 0,
        intent: "Zero scroll"
      }
    });
    assert.equal((invalidScrollCall as any).isError, true);

    // 5. computer_use_drag
    const obsCall4 = await client.callTool({ name: "computer_use_observe", arguments: {} });
    const obsMeta4 = JSON.parse(((obsCall4.content as any[])[0] as any).text);
    const dragCall = await client.callTool({
      name: "computer_use_drag",
      arguments: {
        capture_id: obsMeta4.capture_id,
        topology_version: obsMeta4.topology_version,
        start_x: 100,
        start_y: 100,
        end_x: 400,
        end_y: 400,
        button: "left",
        intent: "Drag window"
      }
    });
    assert.equal((dragCall as any).isError, undefined);

    await client.close();
    await server.close();
  });
});

describe("Defect 4 & 5 Hardened Validation Tests", () => {
  test("AXTreeDataSchema positive and negative validation", () => {
    const validTreeData = {
      target_app: { pid: 123, bundle_id: "com.apple.calc", name: "Calc" },
      topology_version: "top-sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      node_count: 2,
      max_depth_reached: 2,
      truncated: false,
      tree: {
        id: "ax-window-1",
        role: "AXWindow",
        bounds: { x: 0, y: 0, width: 500, height: 500 },
        children: [
          {
            id: "ax-button-2",
            role: "AXButton",
            bounds: { x: 10, y: 10, width: 50, height: 20 }
          }
        ]
      }
    };
    assert.equal(AXTreeDataSchema.safeParse(validTreeData).success, true);

    // Negative: node_count mismatch
    const badCountData = { ...validTreeData, node_count: 99 };
    assert.equal(AXTreeDataSchema.safeParse(badCountData).success, false);

    // Negative: max_depth_reached mismatch
    const badDepthData = { ...validTreeData, max_depth_reached: 10 };
    assert.equal(AXTreeDataSchema.safeParse(badDepthData).success, false);

    // Negative: duplicate node ID
    const duplicateIdData = {
      ...validTreeData,
      tree: {
        id: "ax-node-1",
        role: "AXWindow",
        bounds: { x: 0, y: 0, width: 100, height: 100 },
        children: [
          { id: "ax-node-1", role: "AXButton", bounds: { x: 0, y: 0, width: 10, height: 10 } }
        ]
      }
    };
    assert.equal(AXTreeDataSchema.safeParse(duplicateIdData).success, false);

    // Positive: global AX coordinates may be negative on displays left of or above primary.
    const negativeOriginData = {
      ...validTreeData,
      node_count: 1,
      max_depth_reached: 1,
      tree: { id: "ax-1", role: "AXWindow", bounds: { x: -1440, y: -143, width: 10, height: 10 } }
    };
    assert.equal(AXTreeDataSchema.safeParse(negativeOriginData).success, true);

    // Negative: dimensions cannot be negative.
    const negativeSizeData = {
      ...negativeOriginData,
      tree: { id: "ax-1", role: "AXWindow", bounds: { x: -1440, y: -143, width: -1, height: 10 } }
    };
    assert.equal(AXTreeDataSchema.safeParse(negativeSizeData).success, false);

    // Negative: string exceeding 256 chars
    const longStringData = {
      ...validTreeData,
      node_count: 1,
      max_depth_reached: 1,
      tree: { id: "ax-1", role: "AXWindow", title: "A".repeat(300), bounds: { x: 0, y: 0, width: 10, height: 10 } }
    };
    assert.equal(AXTreeDataSchema.safeParse(longStringData).success, false);
  });

  test("DragInputSchema rejects right/middle mouse buttons", () => {
    const validLeftDrag = {
      capture_id: "cap-1",
      topology_version: "top-sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      start_x: 0, start_y: 0, end_x: 100, end_y: 100, button: "left", intent: "drag item"
    };
    assert.equal(DragInputSchema.safeParse(validLeftDrag).success, true);

    const invalidRightDrag = { ...validLeftDrag, button: "right" };
    assert.equal(DragInputSchema.safeParse(invalidRightDrag).success, false);

    const invalidMiddleDrag = { ...validLeftDrag, button: "middle" };
    assert.equal(DragInputSchema.safeParse(invalidMiddleDrag).success, false);
  });
});
