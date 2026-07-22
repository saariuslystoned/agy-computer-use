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

export function classifyNativeAuthoritySelection(input: NativeAuthorityRunnerInput): SelectionResult {
  if (input.listExitCode !== 0) {
    const output = input.listOutput;
    const isRecognizedFallback =
      output.includes("no such module 'XCTest'") ||
      output.includes('no such module "XCTest"') ||
      output.includes("XCTest is not supported") ||
      output.includes("XCTestHelper binary not found");

    if (isRecognizedFallback) {
      return { status: 0, authority: "fallback" };
    }
    return {
      status: 1,
      authority: "none",
      error: `'swift test list' failed closed with build/discovery/manifest error:\n${output}`
    };
  }

  const actualListLines = input.listOutput
    .trim()
    .split("\n")
    .map(l => l.trim())
    .filter(l => l.startsWith("ComputerUseHostTests."))
    .sort();

  if (actualListLines.length === 0) {
    return {
      status: 1,
      authority: "none",
      error: "'swift test list' returned status 0 with 0 discovered tests. Failing closed."
    };
  }

  const expectedList = input.manifestContent
    .trim()
    .split("\n")
    .map(l => l.trim())
    .filter(Boolean)
    .sort()
    .join("\n");

  const actualListStr = actualListLines.join("\n");

  if (actualListStr !== expectedList) {
    return {
      status: 1,
      authority: "none",
      error: `Native test manifest mismatch!\nExpected:\n${expectedList}\nActual:\n${actualListStr}`
    };
  }

  return {
    status: 0,
    authority: "xctest",
    testCount: actualListLines.length
  };
}
