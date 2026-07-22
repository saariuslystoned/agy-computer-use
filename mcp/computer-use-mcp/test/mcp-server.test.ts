import { test, describe } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "path";
import * as net from "net";
import * as crypto from "crypto";
import AjvModule from "ajv";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createComputerUseServer, validateAndDecodeBase64JPEG, parseJPEGDimensions } from "../src/index.js";
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

  test("Decoder-invocation seam: accepts exact N=10,485,760 byte boundary", () => {
    let decodeCount = 0;
    const mockDecoder = (str: string, enc: BufferEncoding) => {
      decodeCount++;
      // Return minimal valid JPEG buffer for test seam
      return Buffer.from([0xff, 0xd8, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x0a, 0x00, 0x0a, 0x01, 0x01, 0x11, 0x00, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0xff, 0xd9]);
    };
    // 10,485,760 bytes in Base64 (13,981,016 chars with '==' padding)
    const b64_N = "A".repeat(13_981_014) + "==";
    assert.doesNotThrow(() => validateAndDecodeBase64JPEG(b64_N, 10, 10, mockDecoder));
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
      "status_response.json": { expectedValid: true, schemaTarget: "StatusResponse" },
      "observe_response.json": { expectedValid: true, schemaTarget: "ObserveResponse" },
      "permission_denied_response.json": { expectedValid: true, schemaTarget: "ErrorResponse" },
      "stale_topology_response.json": { expectedValid: true, schemaTarget: "ErrorResponse" },
      "timeout_response.json": { expectedValid: true, schemaTarget: "ErrorResponse" },
      "ax_tree_unreachable_response.json": { expectedValid: true, schemaTarget: "ErrorResponse" },
      "click_request_disabled.json": { expectedValid: false },
      "invalid_click_request_negative.json": { expectedValid: false },
      "invalid_method_request_negative.json": { expectedValid: false }
    };

    const fixtureFiles = fs.readdirSync(fixturesDir).filter(f => f.endsWith(".json"));
    assert.ok(fixtureFiles.length >= 5, "Must contain active D2 fixtures");

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

  test("Section 4 & Section 5: Golden JPEG fixture parity and capture boundaries", () => {
    const rootDir = path.resolve(process.cwd(), "../../");
    const docFixturePath = path.join(rootDir, "docs/fixtures/golden_progressive.jpg");
    const mcpFixturePath = path.join(process.cwd(), "test/fixtures/golden_progressive.jpg");

    assert.ok(fs.existsSync(docFixturePath), "docs/fixtures/golden_progressive.jpg must exist");
    assert.ok(fs.existsSync(mcpFixturePath), "mcp/test/fixtures/golden_progressive.jpg must exist");

    const docBuf = fs.readFileSync(docFixturePath);
    const mcpBuf = fs.readFileSync(mcpFixturePath);

    const docHash = crypto.createHash("sha256").update(docBuf).digest("hex");
    const mcpHash = crypto.createHash("sha256").update(mcpBuf).digest("hex");

    assert.equal(docHash, mcpHash, "Both golden_progressive.jpg fixture files must be byte-identical SHA-256");

    // 14-Mutation Parity Table against golden_progressive.jpg
    const goldenBuf = docBuf;

    // 1. Identity
    assert.deepEqual(parseJPEGDimensions(goldenBuf), { width: 10, height: 10 });

    // 2. Malformed APP/COM length
    const mut2 = Buffer.from(goldenBuf);
    mut2[4] = 0x00; mut2[5] = 0x01;
    assert.equal(parseJPEGDimensions(mut2), null);

    // 3. Duplicate SOF IDs
    const mut3 = Buffer.from(goldenBuf);
    const sofIdx3 = mut3.indexOf(Buffer.from([0xff, 0xc2]));
    if (sofIdx3 !== -1) mut3[sofIdx3 + 13] = mut3[sofIdx3 + 10];
    assert.equal(parseJPEGDimensions(mut3), null);

    // 4. Duplicate same-SOS selectors
    const mut4 = Buffer.from(goldenBuf);
    const sosIdx4 = mut4.indexOf(Buffer.from([0xff, 0xda]));
    if (sosIdx4 !== -1) mut4[sosIdx4 + 7] = mut4[sosIdx4 + 5];
    assert.equal(parseJPEGDimensions(mut4), null);

    // 5. Unknown selector in SOS
    const mut5 = Buffer.from(goldenBuf);
    const sosIdx5 = mut5.indexOf(Buffer.from([0xff, 0xda]));
    if (sosIdx5 !== -1) mut5[sosIdx5 + 5] = 0x99;
    assert.equal(parseJPEGDimensions(mut5), null);

    // 6. Zero/excess counts in SOS
    const mut6a = Buffer.from(goldenBuf);
    const sosIdx6a = mut6a.indexOf(Buffer.from([0xff, 0xda]));
    if (sosIdx6a !== -1) mut6a[sosIdx6a + 4] = 0;
    assert.equal(parseJPEGDimensions(mut6a), null);

    const mut6b = Buffer.from(goldenBuf);
    const sosIdx6b = mut6b.indexOf(Buffer.from([0xff, 0xda]));
    if (sosIdx6b !== -1) mut6b[sosIdx6b + 4] = 5;
    assert.equal(parseJPEGDimensions(mut6b), null);

    // 7. Repeated SOI
    const mut7 = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xd8]), goldenBuf.subarray(2)]);
    assert.equal(parseJPEGDimensions(mut7), null);

    // 8. Duplicate SOF
    const sofIdx8 = goldenBuf.indexOf(Buffer.from([0xff, 0xc2]));
    if (sofIdx8 !== -1) {
      const segLen8 = (goldenBuf[sofIdx8 + 2] << 8) | goldenBuf[sofIdx8 + 3];
      const sofChunk = goldenBuf.subarray(sofIdx8, sofIdx8 + 2 + segLen8);
      const mut8 = Buffer.concat([goldenBuf.subarray(0, sofIdx8 + 2 + segLen8), sofChunk, goldenBuf.subarray(sofIdx8 + 2 + segLen8)]);
      assert.equal(parseJPEGDimensions(mut8), null);
    }

    // 9. Bad inter-scan marker/length
    const mut9 = Buffer.from(goldenBuf);
    const sosIdx9 = mut9.indexOf(Buffer.from([0xff, 0xda]));
    if (sosIdx9 !== -1) {
      for (let i = sosIdx9 + 10; i < mut9.length - 1; i++) {
        if (mut9[i] === 0xff && mut9[i + 1] !== 0x00 && !(mut9[i + 1] >= 0xd0 && mut9[i + 1] <= 0xd7) && mut9[i + 1] !== 0xd9) {
          mut9[i + 1] = 0x02;
          break;
        }
      }
    }
    assert.equal(parseJPEGDimensions(mut9), null);

    // 10. Truncated entropy
    const mut10 = goldenBuf.subarray(0, goldenBuf.length - 10);
    assert.equal(parseJPEGDimensions(mut10), null);

    // 11. Missing EOI
    const mut11 = goldenBuf.subarray(0, goldenBuf.length - 2);
    assert.equal(parseJPEGDimensions(mut11), null);

    // 12. Exact 64M (8000x8000)
    const mut12 = Buffer.from(goldenBuf);
    const sofIdx12 = mut12.indexOf(Buffer.from([0xff, 0xc2]));
    if (sofIdx12 !== -1) {
      mut12[sofIdx12 + 5] = 0x1f; mut12[sofIdx12 + 6] = 0x40;
      mut12[sofIdx12 + 7] = 0x1f; mut12[sofIdx12 + 8] = 0x40;
    }
    assert.deepEqual(parseJPEGDimensions(mut12), { width: 8000, height: 8000 });

    // 13. 64M+1 (8000x8001 = 64,008,000)
    const mut13 = Buffer.from(goldenBuf);
    const sofIdx13 = mut13.indexOf(Buffer.from([0xff, 0xc2]));
    if (sofIdx13 !== -1) {
      mut13[sofIdx13 + 5] = 0x1f; mut13[sofIdx13 + 6] = 0x41;
      mut13[sofIdx13 + 7] = 0x1f; mut13[sofIdx13 + 8] = 0x40;
    }
    assert.equal(parseJPEGDimensions(mut13), null);

    // 14. Canonical trailing-byte policy
    const mut14a = Buffer.concat([goldenBuf, Buffer.from([0x00, 0x00])]);
    assert.deepEqual(parseJPEGDimensions(mut14a), { width: 10, height: 10 });

    const mut14b = Buffer.concat([goldenBuf, Buffer.from([0xaa])]);
    assert.equal(parseJPEGDimensions(mut14b), null);
  });

  test("Section 5: Dimension rejection bounds (0, negative, overflow, >64M)", () => {
    const zeroWidthBuf = Buffer.from([
      0xff, 0xd8, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x64, 0x00, 0x00, 0x01, 0x01, 0x11, 0x00, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0xff, 0xd9
    ]);
    assert.equal(parseJPEGDimensions(zeroWidthBuf), null);

    const over64MBuf = Buffer.from([
      0xff, 0xd8, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x1f, 0x41, 0x1f, 0x40, 0x01, 0x01, 0x11, 0x00, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0xff, 0xd9
    ]);
    assert.equal(parseJPEGDimensions(over64MBuf), null);

    const exact64MBuf = Buffer.from([
      0xff, 0xd8, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x1f, 0x40, 0x1f, 0x40, 0x01, 0x01, 0x11, 0x00, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0xff, 0xd9
    ]);
    assert.deepEqual(parseJPEGDimensions(exact64MBuf), { width: 8000, height: 8000 });
  });
});
