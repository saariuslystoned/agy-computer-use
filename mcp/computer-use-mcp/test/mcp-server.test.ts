import { test, describe } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as net from "net";
import AjvModule from "ajv";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createComputerUseServer } from "../src/index.js";
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

describe("Computer Use MCP Server & HostClient Test Suite (Milestone D2)", () => {
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

    // Verify all 6 action tools publish maxLength: 200 and pattern: ^.*\S.*$ on intent in inputSchema
    const actionTools = ["computer_use_click", "computer_use_move", "computer_use_drag", "computer_use_type", "computer_use_shortcut", "computer_use_scroll"];
    for (const toolName of actionTools) {
      const tool = toolsResult.tools.find(t => t.name === toolName);
      assert.ok(tool, `Tool ${toolName} must be listed`);
      const intentProp = (tool.inputSchema.properties as any).intent;
      assert.ok(intentProp, `Tool ${toolName} must have intent property`);
      assert.equal(intentProp.maxLength, 200, `Tool ${toolName} intent property must declare maxLength: 200`);
      assert.equal(intentProp.pattern, "^.*\\S.*$", `Tool ${toolName} intent property must declare non-whitespace regex pattern`);
    }

    // 2. Call status
    const statusCall = await client.callTool({ name: "computer_use_status", arguments: {} });
    assert.ok(statusCall.content);
    const statusText = JSON.parse((statusCall.content as any[])[0].text);
    assert.equal(statusText.connected, true);
    assert.equal(statusText.input_mutation_state, "enabled");
    assert.ok(statusText.topology);

    // 3. Call observe
    const obsCall = await client.callTool({ name: "computer_use_observe", arguments: {} });
    assert.ok(obsCall.content);
    const obsContent = obsCall.content as any[];
    assert.equal(obsContent.length, 2);
    const textMeta = JSON.parse(obsContent[0].text);
    const cap1 = textMeta.capture_id;
    assert.ok(cap1);

    // 4. Call click action
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

    // 5. Call type action with press_enter: true adapter
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

    // 6. Call scroll action with direction adapter
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

  test("Verifies MUTATION_DISABLED response behavior when input mutations are locked out", async () => {
    const mockHost = new MockHostClient();
    mockHost.inputMutationState = "disabled";
    const server = createComputerUseServer(mockHost);

    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    const client = new Client(
      { name: "test-client-disabled", version: "1.0.0" },
      { capabilities: {} }
    );

    await Promise.all([
      server.connect(serverTransport),
      client.connect(clientTransport)
    ]);

    const clickCall = await client.callTool({
      name: "computer_use_click",
      arguments: {
        x: 500,
        y: 500,
        button: "left",
        click_count: 1,
        capture_id: "cap-dummy",
        topology_version: "top-v1",
        intent: "Test disabled click"
      }
    });

    assert.equal((clickCall as any).isError, true);
    const errContent = JSON.parse(((clickCall.content as any[])[0] as any).text);
    assert.equal(errContent.error.code, "MUTATION_DISABLED");

    await client.close();
    await server.close();
  });

  test("Integration path: Official MCP Client -> createComputerUseServer -> UnixSocketHostClient -> UDS Socket", async () => {
    const sockPath = `/tmp/test-mcp-uds-${Date.now()}.sock`;
    const socketServer = net.createServer((socket) => {
      socket.on("data", (data) => {
        if (data.length >= 4) {
          const bodyLen = data.readUInt32BE(0);
          if (data.length >= 4 + bodyLen) {
            const reqBuf = data.subarray(4, 4 + bodyLen);
            const reqObj = JSON.parse(reqBuf.toString("utf-8"));
            const respObj = {
              id: reqObj.id,
              success: true,
              data: { connected: true, topology_version: "top-v1", input_mutation_state: "disabled" }
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
    assert.equal(textRes.topology_version, "top-v1");

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

  test("Validates all golden JSON fixtures in docs/fixtures/ against protocol_schema.json (Ajv) & Zod schemas", () => {
    const rootDir = path.resolve(process.cwd(), "../../");
    const fixturesDir = path.join(rootDir, "docs/fixtures");
    const schemaPath = path.join(rootDir, "docs/protocol_schema.json");

    assert.ok(fs.existsSync(fixturesDir), "docs/fixtures directory must exist");
    assert.ok(fs.existsSync(schemaPath), "docs/protocol_schema.json must exist");

    const schemaContent = fs.readFileSync(schemaPath, "utf-8");
    const protocolSchema = JSON.parse(schemaContent);

    const ajv = new Ajv({ allErrors: true });
    const validateProtocol = ajv.compile(protocolSchema);

    const fixtureFiles = fs.readdirSync(fixturesDir).filter(f => f.endsWith(".json"));
    assert.ok(fixtureFiles.length >= 5, "Must contain at least 5 positive and negative golden fixtures");

    for (const file of fixtureFiles) {
      const content = fs.readFileSync(path.join(fixturesDir, file), "utf-8");
      assert.doesNotThrow(() => JSON.parse(content), `Fixture '${file}' must be valid JSON`);
      const parsed = JSON.parse(content);
      assert.ok(parsed.id, `Fixture '${file}' must contain id`);

      if (file.endsWith("_negative.json")) {
        const isValid = validateProtocol(parsed);
        assert.equal(isValid, false, `Negative fixture '${file}' must fail Ajv protocol schema validation`);
      } else {
        const isValid = validateProtocol(parsed);
        assert.ok(isValid, `Positive fixture '${file}' must pass Ajv protocol schema validation: ${JSON.stringify(validateProtocol.errors)}`);

        if (typeof parsed.success === "boolean") {
          const zodParse = IPCResponseSchema.safeParse(parsed);
          assert.ok(zodParse.success, `Response fixture '${file}' must validate against IPCResponseSchema: ${zodParse.error?.message}`);
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
      // Intentionally do not respond
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
      // Hold socket open
    });

    await new Promise<void>((res) => server.listen(sockPath, res));

    const client = new UnixSocketHostClient(sockPath, 5000);

    // Pre-dispatch abort
    const controller1 = new AbortController();
    controller1.abort();
    const resp1 = await client.request("click", { x: 500, y: 500, capture_id: "cap-1", topology_version: "top-v1", intent: "Click" }, controller1.signal);
    assert.equal(resp1.success, false);
    assert.equal(resp1.error?.code, "CANCELLED");

    // Post-dispatch mutation abort
    const controller2 = new AbortController();
    const reqPromise = client.request("click", { x: 500, y: 500, capture_id: "cap-1", topology_version: "top-v1", intent: "Click" }, controller2.signal);

    setTimeout(() => {
      controller2.abort();
    }, 50);

    const resp2 = await reqPromise;
    assert.equal(resp2.success, false);
    assert.equal(resp2.error?.code, "ACTION_OUTCOME_UNKNOWN");

    server.close();
    if (fs.existsSync(sockPath)) fs.unlinkSync(sockPath);
  });
});
