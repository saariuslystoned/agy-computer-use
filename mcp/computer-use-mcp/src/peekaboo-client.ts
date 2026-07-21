import * as fs from "fs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

export interface PeekabooCanaryResult {
  imageBase64: string;
  mimeType: "image/png" | "image/jpeg";
}

export interface PeekabooImageClient {
  captureCalculator(): Promise<PeekabooCanaryResult>;
}

export interface PeekabooMcpRawClient {
  callImageTool(): Promise<unknown>;
}

export const VALID_DUMMY_PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
export const VALID_DUMMY_JPEG_BASE64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=";

const MAX_DECODED_BYTES = 16 * 1024 * 1024; // 16 MiB cap

export function validateImageMagicBytes(buffer: Buffer, mimeType: string): boolean {
  if (buffer.length < 4) return false;

  if (mimeType === "image/png") {
    return buffer[0] === 0x89 && buffer[1] === 0x50 && buffer[2] === 0x4e && buffer[3] === 0x47;
  }

  if (mimeType === "image/jpeg") {
    return buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff;
  }

  return false;
}

export function parseAndValidateRawImageResponse(raw: unknown): PeekabooCanaryResult {
  if (!raw || typeof raw !== "object") {
    throw new Error("CANARY_RESPONSE_INVALID");
  }

  const obj = raw as Record<string, unknown>;

  if (obj.isError === true) {
    throw new Error("CANARY_PEEKABOO_ERROR");
  }

  const content = obj.content;
  if (!Array.isArray(content) || content.length !== 1) {
    throw new Error("CANARY_CONTENT_INVALID_COUNT");
  }

  const item = content[0] as Record<string, unknown>;
  if (!item || typeof item !== "object" || item.type !== "image") {
    throw new Error("CANARY_CONTENT_NOT_IMAGE");
  }

  const mimeType = item.mimeType;
  if (mimeType !== "image/png" && mimeType !== "image/jpeg") {
    throw new Error("CANARY_UNSUPPORTED_MIME");
  }

  const data = item.data;
  if (!data || typeof data !== "string") {
    throw new Error("CANARY_EMPTY_BASE64");
  }

  const cleanData = data.replace(/[\r\n\s]/g, "");
  const base64Regex = /^[A-Za-z0-9+/=]+$/;
  if (!base64Regex.test(cleanData)) {
    throw new Error("CANARY_MALFORMED_BASE64");
  }

  const decodedBuf = Buffer.from(cleanData, "base64");
  if (decodedBuf.length === 0) {
    throw new Error("CANARY_EMPTY_DECODED_BUFFER");
  }

  if (decodedBuf.length > MAX_DECODED_BYTES) {
    throw new Error("CANARY_SIZE_EXCEEDED");
  }

  if (!validateImageMagicBytes(decodedBuf, mimeType)) {
    throw new Error("CANARY_MAGIC_MISMATCH");
  }

  return {
    imageBase64: cleanData,
    mimeType: mimeType as "image/png" | "image/jpeg"
  };
}

export class MockPeekabooMcpRawClient implements PeekabooMcpRawClient {
  private rawResponse: unknown;

  constructor(rawResponse?: unknown) {
    this.rawResponse = rawResponse ?? {
      content: [
        {
          type: "image",
          data: VALID_DUMMY_PNG_BASE64,
          mimeType: "image/png"
        }
      ]
    };
  }

  public async callImageTool(): Promise<unknown> {
    return this.rawResponse;
  }
}

export class MockPeekabooImageClient implements PeekabooImageClient {
  private rawClient: PeekabooMcpRawClient;

  constructor(rawResponse?: unknown) {
    this.rawClient = new MockPeekabooMcpRawClient(rawResponse);
  }

  public async captureCalculator(): Promise<PeekabooCanaryResult> {
    const raw = await this.rawClient.callImageTool();
    return parseAndValidateRawImageResponse(raw);
  }
}

export class StdioPeekabooMcpRawClient implements PeekabooMcpRawClient {
  private peekabooBin: string;

  constructor(peekabooBin = "/opt/homebrew/bin/peekaboo") {
    this.peekabooBin = fs.existsSync(peekabooBin) ? peekabooBin : "peekaboo";
  }

  public async callImageTool(): Promise<unknown> {
    const envObj = Object.fromEntries(
      Object.entries(process.env).filter(([_, v]) => v !== undefined)
    ) as Record<string, string>;

    const transport = new StdioClientTransport({
      command: this.peekabooBin,
      args: ["mcp", "serve"],
      env: envObj,
      stderr: "ignore" // Prevent stdio pipe deadlocks
    });

    const client = new Client(
      { name: "computer-use-canary-bridge", version: "0.1.0" },
      { capabilities: {} }
    );

    let timeoutId: NodeJS.Timeout | undefined;

    try {
      const connectAndCall = async () => {
        await client.connect(transport);
        return await client.callTool({
          name: "image",
          arguments: {
            app_target: "Calculator",
            format: "data",
            max_dimension: 640,
            capture_focus: "background"
          }
        });
      };

      const timeoutPromise = new Promise<never>((_, reject) => {
        timeoutId = setTimeout(() => {
          reject(new Error("CANARY_TIMEOUT"));
        }, 5000);
      });

      const res = await Promise.race([connectAndCall(), timeoutPromise]);
      return res;
    } finally {
      if (timeoutId) clearTimeout(timeoutId);
      try { await client.close(); } catch {}
      try { await transport.close(); } catch {}
    }
  }
}

export class PeekabooImageClientImpl implements PeekabooImageClient {
  private rawClient: PeekabooMcpRawClient;

  constructor(rawClient?: PeekabooMcpRawClient) {
    this.rawClient = rawClient ?? new StdioPeekabooMcpRawClient();
  }

  public async captureCalculator(): Promise<PeekabooCanaryResult> {
    const raw = await this.rawClient.callImageTool();
    return parseAndValidateRawImageResponse(raw);
  }
}
