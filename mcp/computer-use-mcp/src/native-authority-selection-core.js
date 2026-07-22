/**
 * Pure ESM classifier for native test authority selection.
 * Shared directly by bin/agy-computer-use and mcp/computer-use-mcp.
 */
export function classifyNativeAuthoritySelection(input) {
  if (input.listExitCode !== 0) {
    const output = input.listOutput || "";
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

  const rawListLines = (input.listOutput || "")
    .trim()
    .split("\n")
    .map(l => l.trim())
    .filter(l => l.startsWith("ComputerUseHostTests."));

  if (new Set(rawListLines).size !== rawListLines.length) {
    return {
      status: 1,
      authority: "none",
      error: "'swift test list' output contains duplicate entries. Failing closed."
    };
  }

  const actualListLines = [...rawListLines].sort();

  if (actualListLines.length === 0) {
    return {
      status: 1,
      authority: "none",
      error: "'swift test list' returned status 0 with 0 discovered tests. Failing closed."
    };
  }

  const expectedList = (input.manifestContent || "")
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
