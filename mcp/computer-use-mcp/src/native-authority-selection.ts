export interface SelectionResult {
  status: number;
  authority: "xctest" | "fallback" | "none";
  error?: string;
  testCount?: number;
}

export interface NativeAuthorityRunnerInput {
  helpOutput: string;
  listOutput: string;
  listExitCode: number;
  manifestContent: string;
}

// @ts-ignore JS import
export { classifyNativeAuthoritySelection } from "./native-authority-selection-core.js";
