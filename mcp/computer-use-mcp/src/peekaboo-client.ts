import { spawn } from "child_process";
import * as fs from "fs";
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

const MAX_IMAGE_SIZE = 16 * 1024 * 1024; // 16 MB cap

export class StdioPeekabooImageClient implements PeekabooImageClient {
  private peekabooBin: string;

  constructor(peekabooBin = "/opt/homebrew/bin/peekaboo") {
    this.peekabooBin = fs.existsSync(peekabooBin) ? peekabooBin : "peekaboo";
  }

  public async captureCalculator(): Promise<PeekabooCanaryResult> {
    return new Promise((resolve, reject) => {
      // Spawn peekaboo image command to capture Calculator into stdout JSON/base64 or temp png
      const tmpPath = `/tmp/canary-calc-${Date.now()}-${Math.random().toString(36).slice(2)}.png`;
      const args = ["image", "--app", "Calculator", "--path", tmpPath, "--format", "png", "--capture-focus", "background"];

      const child = spawn(this.peekabooBin, args, {
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env }
      });

      let stderrBuf = "";

      child.stderr.on("data", (chunk) => {
        stderrBuf += chunk.toString("utf-8");
      });

      child.on("error", (err) => {
        if (fs.existsSync(tmpPath)) try { fs.unlinkSync(tmpPath); } catch {}
        reject(new Error(`Failed to spawn Peekaboo process: ${err.message}`));
      });

      child.on("close", (code) => {
        if (code !== 0) {
          if (fs.existsSync(tmpPath)) try { fs.unlinkSync(tmpPath); } catch {}
          reject(new Error(`Peekaboo image capture exited with code ${code}. Stderr: ${stderrBuf}`));
          return;
        }

        try {
          if (!fs.existsSync(tmpPath)) {
            reject(new Error(`Peekaboo did not produce image file at expected path ${tmpPath}`));
            return;
          }

          const fileBuf = fs.readFileSync(tmpPath);
          fs.unlinkSync(tmpPath);

          if (fileBuf.length > MAX_IMAGE_SIZE) {
            reject(new Error(`Captured image size ${fileBuf.length} bytes exceeds 16MB limit`));
            return;
          }

          const base64Str = fileBuf.toString("base64");
          if (!base64Str || base64Str.length === 0) {
            reject(new Error("Captured image produced empty base64 string"));
            return;
          }

          resolve({
            imageBase64: base64Str,
            mimeType: "image/png"
          });
        } catch (err: unknown) {
          if (fs.existsSync(tmpPath)) try { fs.unlinkSync(tmpPath); } catch {}
          const errMsg = err instanceof Error ? err.message : String(err);
          reject(new Error(`Failed reading captured Peekaboo image: ${errMsg}`));
        }
      });
    });
  }
}
