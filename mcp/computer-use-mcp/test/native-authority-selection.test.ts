import { describe, it } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as child_process from "node:child_process";
import { classifyNativeAuthoritySelection } from "../src/native-authority-selection.js";

const sampleManifest = `ComputerUseHostTests.ComputerUseHostTests/test01_LengthPrefixedFraming
ComputerUseHostTests.ComputerUseHostTests/test02_OversizedFramingHeaderRejection`;

describe("Native Authority Selection Classification Table", () => {
  it("1. Exact list success -> selects XCTest authority with status 0", () => {
    const res = classifyNativeAuthoritySelection({
      helpOutput: "Usage: swift test list [--enable-xctest]",
      listOutput: `ComputerUseHostTests.ComputerUseHostTests/test01_LengthPrefixedFraming\nComputerUseHostTests.ComputerUseHostTests/test02_OversizedFramingHeaderRejection`,
      listExitCode: 0,
      manifestContent: sampleManifest
    });
    assert.equal(res.status, 0);
    assert.equal(res.authority, "xctest");
    assert.equal(res.testCount, 2);
  });

  it("2. Exit-zero empty discovery -> fails closed with status 1", () => {
    const res = classifyNativeAuthoritySelection({
      helpOutput: "",
      listOutput: "Build complete!\n",
      listExitCode: 0,
      manifestContent: sampleManifest
    });
    assert.equal(res.status, 1);
    assert.equal(res.authority, "none");
    assert.match(res.error || "", /0 discovered tests/);
  });

  it("3. Missing names in discovered list -> fails closed with status 1", () => {
    const res = classifyNativeAuthoritySelection({
      helpOutput: "",
      listOutput: `ComputerUseHostTests.ComputerUseHostTests/test01_LengthPrefixedFraming`,
      listExitCode: 0,
      manifestContent: sampleManifest
    });
    assert.equal(res.status, 1);
    assert.equal(res.authority, "none");
    assert.match(res.error || "", /manifest mismatch/i);
  });

  it("4. Extra names in discovered list -> fails closed with status 1", () => {
    const res = classifyNativeAuthoritySelection({
      helpOutput: "",
      listOutput: `ComputerUseHostTests.ComputerUseHostTests/test01_LengthPrefixedFraming\nComputerUseHostTests.ComputerUseHostTests/test02_OversizedFramingHeaderRejection\nComputerUseHostTests.ComputerUseHostTests/test99_Extra`,
      listExitCode: 0,
      manifestContent: sampleManifest
    });
    assert.equal(res.status, 1);
    assert.equal(res.authority, "none");
    assert.match(res.error || "", /manifest mismatch/i);
  });

  it("5. Duplicate names in discovered list -> fails closed with status 1", () => {
    const res = classifyNativeAuthoritySelection({
      helpOutput: "",
      listOutput: `ComputerUseHostTests.ComputerUseHostTests/test01_LengthPrefixedFraming\nComputerUseHostTests.ComputerUseHostTests/test01_LengthPrefixedFraming`,
      listExitCode: 0,
      manifestContent: sampleManifest
    });
    assert.equal(res.status, 1);
    assert.equal(res.authority, "none");
    assert.match(res.error || "", /duplicate entries|manifest mismatch/i);
  });

  it("6. Compiler failure -> fails closed with status 1", () => {
    const res = classifyNativeAuthoritySelection({
      helpOutput: "",
      listOutput: "error: cannot find type 'Foo' in scope",
      listExitCode: 1,
      manifestContent: sampleManifest
    });
    assert.equal(res.status, 1);
    assert.equal(res.authority, "none");
    assert.match(res.error || "", /build\/discovery\/manifest error/i);
  });

  it("7. Unrecognized nonzero exit -> fails closed with status 1", () => {
    const res = classifyNativeAuthoritySelection({
      helpOutput: "",
      listOutput: "error: unknown internal runner fault",
      listExitCode: 1,
      manifestContent: sampleManifest
    });
    assert.equal(res.status, 1);
    assert.equal(res.authority, "none");
    assert.match(res.error || "", /failed closed/i);
  });

  it("8. Unsupported-XCTest fallback route -> selects fallback authority with status 0", () => {
    const res = classifyNativeAuthoritySelection({
      helpOutput: "",
      listOutput: "error: no such module 'XCTest'",
      listExitCode: 1,
      manifestContent: sampleManifest
    });
    assert.equal(res.status, 0);
    assert.equal(res.authority, "fallback");
  });
});

describe("Hermetic Child-Process CLI Authority Selection (`bin/agy-computer-use test-native`)", () => {
  it("Executes bin/agy-computer-use test-native with stubbed swift binary in PATH", () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "agy-cli-test-"));
    const binDir = path.join(tmpDir, "bin");
    fs.mkdirSync(binDir, { recursive: true });

    const stubSwift = path.join(binDir, "swift");
    fs.writeFileSync(
      stubSwift,
      `#!/bin/sh
if [ "$1" = "test" ] && [ "$2" = "--help" ]; then
  echo "Usage: swift test"
  exit 0
fi
if [ "$1" = "test" ] && [ "$2" = "list" ]; then
  echo "error: no such module 'XCTest'"
  exit 1
fi
if [ "$1" = "run" ]; then
  echo "[ComputerUseHostTestRunner] Executed 37 native test cases successfully. ALL PASSED."
  exit 0
fi
exit 0
`,
      { mode: 0o755 }
    );

    const repoRoot = path.resolve(process.cwd(), "../../");
    const cliBin = path.join(repoRoot, "bin/agy-computer-use");
    const env = { ...process.env, PATH: `${binDir}:${process.env.PATH}` };

    const out = child_process.execSync(`node ${cliBin} test-native`, { env, cwd: repoRoot }).toString();
    assert.match(out, /XCTest discovery unavailable in environment/);
    assert.match(out, /Native test suite execution complete/);

    fs.rmSync(tmpDir, { recursive: true, force: true });
  });
});
