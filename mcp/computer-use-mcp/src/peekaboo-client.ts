import * as fs from "fs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { Logger } from "./logger.js";

export interface PeekabooCanaryResult {
  imageBase64: string;
  mimeType: "image/png" | "image/jpeg";
}

export interface PeekabooImageClient {
  captureCalculator(): Promise<PeekabooCanaryResult>;
}

export const VALID_DUMMY_JPEG_BASE64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=";

export class MockPeekabooImageClient implements PeekabooImageClient {
  private fakeResult: PeekabooCanaryResult;

  constructor(fakeResult?: PeekabooCanaryResult) {
    this.fakeResult = fakeResult ?? {
      imageBase64: VALID_DUMMY_JPEG_BASE64,
      mimeType: "image/jpeg"
    };
  }

  public async captureCalculator(): Promise<PeekabooCanaryResult> {
    return this.fakeResult;
  }
}

export class StdioPeekabooImageClient implements PeekabooImageClient {
  private peekabooBin: string;

  constructor(peekabooBin = "/opt/homebrew/bin/peekaboo") {
    this.peekabooBin = fs.existsSync(peekabooBin) ? peekabooBin : "peekaboo";
  }

  public async captureCalculator(): Promise<PeekabooCanaryResult> {
    const transport = new StdioClientTransport({
      command: this.peekabooBin,
      args: ["mcp"]
    });

    const client = new Client(
      { name: "computer-use-canary-bridge", version: "0.1.0" },
      { capabilities: {} }
    );

    try {
      await client.connect(transport);

      const result = await client.callTool({
        name: "image",
        arguments: {
          app_target: "Calculator",
          format: "data",
          max_dimension: 640,
          capture_focus: "background"
        }
      });

      await client.close();

      if (!result.content || !Array.isArray(result.content)) {
        throw new Error("Peekaboo MCP image tool returned invalid response shape");
      }

      // Filter non-text/non-image content
      const imageItems = result.content.filter((c: any) => c.type === "image");
      if (imageItems.length !== 1) {
        throw new Error(`Peekaboo MCP image tool must return exactly 1 image item, got ${imageItems.length}`);
      }

      const img = imageItems[0] as any;
      if (!img.data || typeof img.data !== "string") {
        throw new Error("Peekaboo MCP image tool returned empty or non-string base64 data");
      }

      const mimeType = img.mimeType === "image/png" ? "image/png" : img.mimeType === "image/jpeg" ? "image/jpeg" : null;
      if (!mimeType) {
        throw new Error(`Peekaboo MCP image tool returned unsupported mimeType '${img.mimeType}'`);
      }

      return {
        imageBase64: img.data,
        mimeType
      };
    } catch (err: unknown) {
      try { await client.close(); } catch {}
      const errMsg = err instanceof Error ? err.message : String(err);
      throw new Error(`Stdio Peekaboo 3.9.1 MCP call failed: ${errMsg}`);
    }
  }
}
