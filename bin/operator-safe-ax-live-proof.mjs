#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { pathToFileURL, fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, "..");
const MCP_PKG_DIR = path.join(REPO_ROOT, "mcp/computer-use-mcp");
const MCP_SERVER_PATH = path.join(REPO_ROOT, "bin/mcp-server.sh");
const MCP_CLIENT_PATH = path.join(MCP_PKG_DIR, "node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js");
const MCP_STDIO_PATH = path.join(MCP_PKG_DIR, "node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js");

const EXIT_SUCCESS = 0;
const EXIT_USAGE = 2;
const EXIT_STATUS_PRECONDITION = 3;
const EXIT_SELECTION = 4;
const EXIT_TOOL_RETRY_EXHAUSTED = 5;
const EXIT_ACTION_FAILED = 6;

const SUPPORTED_AX_ACTION = "press";
const OPERATOR_SAFE_AX_ACTIONS = ["press", "set_value"];

function sha256Hex(value) {
  return createHash("sha256").update(String(value)).digest("hex");
}

function fail(msg, details = {}, exitCode = EXIT_ACTION_FAILED) {
  const err = new Error(msg);
  err.exitCode = exitCode;
  err.details = details;
  throw err;
}

function usage() {
  return `\
Usage:
  node bin/operator-safe-ax-live-proof.mjs --socket <UDS_PATH> --app-id <APP_ID> [options]

Required:
  --socket <path>               Path to the host Unix-domain socket used by AGY.
  --app-id <id>                 Explicit target app id (bundle id / pid / process name).
  One or more exact target selectors:
  --identifier <text>           Exact AX identifier selector.
  --description <text>          Exact AX description selector.
  --title <text>                Exact AX title selector.
  --value <text>                Exact AX value selector.

Optional:
  --before-value <text>         Exact expected value before pressing.
  --after-value <text>          Exact expected value after pressing.
  --intent <text>               Human intent for the AX press action (non-empty).
  --retry-limit <n>             Bounded retries on read-only AX inspection only (default: 2).
  --tool-timeout-ms <n>         Per-MCP tool call timeout in ms (default: 8000).
  --max-depth <1..10>           Optional explicit depth for ax_tree.
  --help                        Show this message.
`;
}

function parseArgs(argv) {
  const args = argv.slice(2);
  const opts = {
    retryLimit: 2,
    toolTimeoutMs: 8000,
    intent: "Operator-safe live proof press"
  };

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];

    if (arg === "--help" || arg === "-h") {
      console.log(usage());
      process.exit(EXIT_SUCCESS);
    }

    if (!arg.startsWith("--")) {
      fail(`Unexpected positional argument: ${arg}`, { arg }, EXIT_USAGE);
    }

    const next = args[i + 1];
    const takeValue = () => {
      if (!next || next.startsWith("--")) {
        fail(`Option ${arg} requires a value`, { option: arg }, EXIT_USAGE);
      }
      i += 1;
      return next;
    };

    switch (arg) {
      case "--socket":
        opts.socket = takeValue();
        break;
      case "--app-id":
        opts.appId = takeValue();
        break;
      case "--title":
        opts.title = takeValue();
        break;
      case "--identifier":
        opts.identifier = takeValue();
        break;
      case "--description":
        opts.description = takeValue();
        break;
      case "--value":
        opts.value = takeValue();
        break;
      case "--before-value":
        opts.beforeValue = takeValue();
        break;
      case "--after-value":
        opts.afterValue = takeValue();
        break;
      case "--intent":
        opts.intent = takeValue();
        break;
      case "--retry-limit": {
        const value = takeValue();
        const n = Number.parseInt(value, 10);
        if (!Number.isInteger(n) || n < 0) {
          fail(`--retry-limit must be an integer >= 0`, { option: arg, value }, EXIT_USAGE);
        }
        opts.retryLimit = n;
        break;
      }
      case "--tool-timeout-ms": {
        const value = takeValue();
        const n = Number.parseInt(value, 10);
        if (!Number.isInteger(n) || n < 250) {
          fail(`--tool-timeout-ms must be an integer >= 250`, { option: arg, value }, EXIT_USAGE);
        }
        opts.toolTimeoutMs = n;
        break;
      }
      case "--max-depth": {
        const value = takeValue();
        const n = Number.parseInt(value, 10);
        if (!Number.isInteger(n) || n < 1 || n > 10) {
          fail(`--max-depth must be between 1 and 10`, { option: arg, value }, EXIT_USAGE);
        }
        opts.maxDepth = n;
        break;
      }
      default:
        fail(`Unknown option: ${arg}`, { option: arg }, EXIT_USAGE);
    }
  }

  if (!opts.socket || !opts.appId) {
    fail("Missing required --socket and/or --app-id", { usage: usage().split("\n")[0] }, EXIT_USAGE);
  }

  if (
    opts.identifier === undefined &&
    opts.description === undefined &&
    opts.title === undefined &&
    opts.value === undefined
  ) {
    fail("At least one exact target selector is required", {
      options: ["--identifier", "--description", "--title", "--value"]
    }, EXIT_USAGE);
  }

  if (typeof opts.intent !== "string" || opts.intent.trim().length === 0) {
    fail("--intent must be a non-empty string", { option: "--intent" }, EXIT_USAGE);
  }

  if (!Number.isInteger(opts.retryLimit) || opts.retryLimit < 0) {
    fail("--retry-limit must be a non-negative integer", { value: opts.retryLimit }, EXIT_USAGE);
  }

  return opts;
}

function extractJsonText(result, toolName) {
  if (!result || !Array.isArray(result.content)) {
    fail(`MCP tool '${toolName}' returned malformed response content`, { tool: toolName }, EXIT_ACTION_FAILED);
  }

  const textBlock = result.content.find((c) => c?.type === "text");
  if (!textBlock || typeof textBlock.text !== "string") {
    fail(`MCP tool '${toolName}' did not return text content`, { tool: toolName }, EXIT_ACTION_FAILED);
  }

  try {
    return JSON.parse(textBlock.text);
  } catch (err) {
    fail(`Unable to parse MCP tool '${toolName}' text payload as JSON`, {
      tool: toolName,
      message: err.message
    }, EXIT_ACTION_FAILED);
  }
}

function parseToolResult(result, toolName) {
  const payload = extractJsonText(result, toolName);

  if (result.isError === true) {
    const toolError = payload?.error || payload;
    return {
      ok: false,
      error: {
        code: typeof toolError?.code === "string" ? toolError.code : "TOOL_ERROR",
        message: typeof toolError?.message === "string" ? toolError.message : `Tool '${toolName}' returned an error`,
        details: toolError?.details
      }
    };
  }

  if (!payload) {
    return {
      ok: false,
      error: {
        code: "EMPTY_PAYLOAD",
        message: `Tool '${toolName}' returned an empty payload`
      }
    };
  }

  return { ok: true, data: payload };
}

function ensureStatusGate(status) {
  const missing = [];

  if (status.connected !== true) {
    missing.push("connected must be true");
  }
  if (status.accessibility_trusted !== true) {
    missing.push("accessibility_trusted must be true");
  }
  if (status.ax_tree_inspection_available !== true) {
    missing.push("ax_tree_inspection_available must be true");
  }
  if (status.operator_safe_ax_available !== true) {
    missing.push("operator_safe_ax_available must be true");
  }

  const actions = Array.isArray(status.operator_safe_ax_actions) ? status.operator_safe_ax_actions : [];
  const canonicalPressOnly = actions.length === 1 && actions[0] === "press";
  const canonicalFull =
    actions.length === OPERATOR_SAFE_AX_ACTIONS.length &&
    actions.every((action, index) => action === OPERATOR_SAFE_AX_ACTIONS[index]);
  if (!canonicalPressOnly && !canonicalFull) {
    missing.push("operator_safe_ax_actions must be ['press'] or canonical ['press', 'set_value']");
  }

  const strategies = Array.isArray(status.supported_action_strategies) ? status.supported_action_strategies : [];
  if (!strategies.includes("ax_semantic")) {
    missing.push("supported_action_strategies must include 'ax_semantic'");
  }

  if (missing.length > 0) {
    fail("AX status gate failed", { code: "STATUS_GATE_FAILED", issues: missing, status }, EXIT_STATUS_PRECONDITION);
  }

  return {
    connected: status.connected,
    accessibility_trusted: status.accessibility_trusted,
    ax_tree_inspection_available: status.ax_tree_inspection_available,
    operator_safe_ax_available: status.operator_safe_ax_available,
    operator_safe_ax_actions: actions,
    supported_action_strategies: strategies
  };
}

function matchesSelector(node, selector) {
  if (selector.identifier !== undefined && node.identifier !== selector.identifier) {
    return false;
  }
  if (selector.description !== undefined && node.description !== selector.description) {
    return false;
  }
  if (selector.title !== undefined && node.title !== selector.title) {
    return false;
  }
  if (selector.value !== undefined && node.value !== selector.value) {
    return false;
  }
  return true;
}

function collectSelectorMatches(node, selector, matches = [], path = []) {
  if (!node || typeof node !== "object") {
    return matches;
  }

  if (matchesSelector(node, selector)) {
    matches.push({
      node,
      path: path.concat(node.id || "?").join("/")
    });
  }

  const children = Array.isArray(node.children) ? node.children : [];
  for (const child of children) {
    collectSelectorMatches(child, selector, matches, path.concat(node.id || "?"));
  }
  return matches;
}

function assertExactlyOneTarget(treePayload, selector, attempt) {
  if (!treePayload || typeof treePayload !== "object") {
    fail("Malformed ax_tree response payload", { code: "INVALID_AX_TREE", attempt }, EXIT_ACTION_FAILED);
  }
  if (treePayload.truncated === true) {
    fail("Refusing to select from a truncated AX tree", {
      code: "AX_TREE_TRUNCATED",
      selector,
      attempt,
      node_count: treePayload.node_count
    }, EXIT_SELECTION);
  }

  const matches = collectSelectorMatches(treePayload.tree, selector);
  if (matches.length === 0) {
    fail("No AX node matched selector", {
      code: "TARGET_NOT_FOUND",
      selector,
      attempt,
      node_count: treePayload.node_count
    }, EXIT_SELECTION);
  }
  if (matches.length > 1) {
    fail("Ambiguous target: multiple AX nodes matched selector", {
      code: "TARGET_AMBIGUOUS",
      selector,
      attempt,
      candidates: matches.slice(0, 5).map((item) => ({
        path: item.path,
        role: item.node.role,
        identifier: item.node.identifier,
        description: item.node.description,
        title: item.node.title,
        value: item.node.value
      })),
      total_candidates: matches.length
    }, EXIT_SELECTION);
  }

  const match = matches[0];
  const hasPress = Array.isArray(match.node.supported_actions)
    && match.node.supported_actions.includes(SUPPORTED_AX_ACTION);
  const enabled = match.node.enabled === true;
  const hasRefs = Boolean(match.node.element_ref);
  if (!hasPress || !enabled || !hasRefs) {
    fail("The sole selector match is not an enabled retained press control", {
      code: "TARGET_NOT_ACTIONABLE",
      selector,
      attempt,
      path: match.path,
      role: match.node.role,
      enabled: match.node.enabled,
      advertises_press: hasPress,
      has_element_ref: hasRefs
    }, EXIT_SELECTION);
  }

  return {
    match,
    summaries: {
      role: match.node.role,
      subrole: match.node.subrole,
      identifier: match.node.identifier,
      description: match.node.description,
      title: match.node.title,
      value: match.node.value,
      enabled: match.node.enabled,
      path: match.path,
      element_ref_hash: sha256Hex(match.node.element_ref).slice(0, 16),
    }
  };
}

async function callToolWithTimeout(client, toolName, args, timeoutMs) {
  return client.callTool(
    { name: toolName, arguments: args || {} },
    undefined,
    {
      timeout: timeoutMs,
      maxTotalTimeout: timeoutMs
    }
  );
}

async function safeCallTool(controller, name, args, timeoutMs, callLabel) {
  let result;
  try {
    result = await callToolWithTimeout(controller.client, name, args, timeoutMs);
  } catch (err) {
    fail(`MCP tool '${name}' call failed`, {
      tool: name,
      operation: callLabel,
      message: err.message
    }, EXIT_ACTION_FAILED);
  }

  const parsed = parseToolResult(result, name);
  if (!parsed.ok) {
    fail(`MCP tool '${name}' returned error`, {
      tool: name,
      code: parsed.error.code,
      message: parsed.error.message
    }, EXIT_ACTION_FAILED, parsed.error);
  }
  return parsed.data;
}

async function inspectAndSelectTarget(controller, opts, selector, maxRetries) {
  const attemptLimit = Math.max(1, maxRetries + 1);
  const attemptErrors = [];

  for (let attempt = 1; attempt <= attemptLimit; attempt += 1) {
    try {
      const treeData = await inspectTree(controller, opts);
      const { match, summaries } = assertExactlyOneTarget(treeData, selector, attempt);

      return {
        attempt,
        treeData,
        match,
        summaries,
      };
    } catch (err) {
      const code = err.details?.code || err.code;
      attemptErrors.push({ attempt, code, message: err.message });
      if (code === "USER_INTERVENED") {
        if (attempt < attemptLimit) {
          // SAFETY REQUIREMENT: do not retry with stale references.
          continue;
        }
        fail("USER_INTERVENED retry limit exhausted for inspection", {
          code: "USER_INTERVENED_RETRY_EXHAUSTED",
          attempts: attemptErrors
        }, EXIT_TOOL_RETRY_EXHAUSTED);
      }
      throw err;
    }
  }

  fail("Inspection loop ended without a result", {
    code: "INSPECTION_LOOP_INVARIANT",
    attempts: attemptErrors
  }, EXIT_ACTION_FAILED);
}

async function inspectTreeWithRetries(controller, opts, maxRetries) {
  const attemptLimit = Math.max(1, maxRetries + 1);
  const attemptErrors = [];

  for (let attempt = 1; attempt <= attemptLimit; attempt += 1) {
    try {
      return {
        attempt,
        treeData: await inspectTree(controller, opts)
      };
    } catch (err) {
      const code = err.details?.code || err.code;
      attemptErrors.push({ attempt, code, message: err.message });
      if (code === "USER_INTERVENED") {
        if (attempt < attemptLimit) {
          continue;
        }
        fail("USER_INTERVENED retry limit exhausted for inspection", {
          code: "USER_INTERVENED_RETRY_EXHAUSTED",
          attempts: attemptErrors
        }, EXIT_TOOL_RETRY_EXHAUSTED);
      }
      throw err;
    }
  }

  fail("Inspection loop ended without a result", {
    code: "INSPECTION_LOOP_INVARIANT",
    attempts: attemptErrors
  }, EXIT_ACTION_FAILED);
}

async function getStatus(controller, opts) {
  const statusPayload = await safeCallTool(controller, "computer_use_status", {}, opts.toolTimeoutMs, "status check");
  const statusData = statusPayload.data || statusPayload;
  return ensureStatusGate(statusData);
}

async function inspectTree(controller, opts) {
  const args = { app_id: opts.appId };
  if (typeof opts.maxDepth === "number") {
    args.max_depth = opts.maxDepth;
  }

  const data = await safeCallTool(controller, "computer_use_ax_tree", args, opts.toolTimeoutMs, "ax_tree");
  return data.data || data;
}

function validateActionReceipt(actionData, expectedRefs) {
  if (actionData.status !== "dispatched") {
    fail("AX action did not return dispatched status", { expected: "dispatched", actual: actionData.status }, EXIT_ACTION_FAILED);
  }
  if (actionData.strategy !== "ax_semantic") {
    fail("AX action did not return ax_semantic strategy", { expected: "ax_semantic", actual: actionData.strategy }, EXIT_ACTION_FAILED);
  }
  if (actionData.requires_reinspection !== true) {
    fail("AX action receipt must require reinspection", { expected: true, actual: actionData.requires_reinspection }, EXIT_ACTION_FAILED);
  }
  if (actionData.global_hid_posts !== 0) {
    fail("AX action receipt must report zero global HID posts", { expected: 0, actual: actionData.global_hid_posts }, EXIT_ACTION_FAILED);
  }

  const exactAuthorityFields = [
    "ax_snapshot_id",
    "app_instance_ref",
    "element_ref",
    "topology_version"
  ];
  for (const field of exactAuthorityFields) {
    if (actionData[field] !== expectedRefs[field]) {
      fail("AX action receipt does not match submitted authority", {
        code: "ACTION_RECEIPT_AUTHORITY_MISMATCH",
        field
      }, EXIT_ACTION_FAILED);
    }
  }
  if (actionData.action !== SUPPORTED_AX_ACTION) {
    fail("AX action receipt does not match submitted action", {
      code: "ACTION_RECEIPT_ACTION_MISMATCH",
      expected: SUPPORTED_AX_ACTION,
      actual: actionData.action
    }, EXIT_ACTION_FAILED);
  }
}

async function performPressFlow(controller, opts, selector) {
  const inspected = await inspectAndSelectTarget(
    controller,
    opts,
    selector,
    opts.retryLimit
  );
  const treeData = inspected.treeData;
  const summaries = inspected.summaries;
  const match = inspected.match;

  const selected = {
    ...summaries,
    tree_node_count: treeData.node_count,
    tree_max_depth_reached: treeData.max_depth_reached,
    tree_truncated: treeData.truncated,
    topology_version: treeData.topology_version,
    ax_snapshot_id_hash: sha256Hex(treeData.ax_snapshot_id).slice(0, 16),
    app_instance_ref_hash: sha256Hex(treeData.app_instance_ref).slice(0, 16),
  };

  const refs = {
    ax_snapshot_id: treeData.ax_snapshot_id,
    app_instance_ref: treeData.app_instance_ref,
    element_ref: match.node.element_ref,
    topology_version: treeData.topology_version
  };

  if (opts.beforeValue !== undefined && match.node.value !== opts.beforeValue) {
    fail("Precondition failed: observed before-value does not match expectation", {
      code: "BEFORE_VALUE_MISMATCH",
      expected: opts.beforeValue,
      actual: match.node.value,
      path: summaries.path
    }, EXIT_SELECTION);
  }

  // Never automatically retry ax_action. USER_INTERVENED may be detected
  // after AXPress dispatch, so its outcome can already have changed the target.
  let actionData;
  try {
    const actionPayload = await safeCallTool(
      controller,
      "computer_use_ax_action",
      {
        ...refs,
        action: SUPPORTED_AX_ACTION,
        intent: opts.intent
      },
      opts.toolTimeoutMs,
      "single ax_action dispatch"
    );
    actionData = actionPayload.data || actionPayload;
    validateActionReceipt(actionData, refs);
  } catch (err) {
    let recoveryReinspection = null;
    let recoveryReinspectionError = null;
    try {
      // Settle/cancel the SDK request before this point, then retire its MCP
      // child. A fresh MCP process opens the next native UDS connection.
      // ComputerUseHost accepts and completes one connection at a time, so the
      // resulting AX tree cannot overtake an already-received AX action.
      if (typeof controller.reconnectForRecovery !== "function") {
        fail("Action-side recovery requires a fresh MCP controller", {
          code: "RECOVERY_TRANSPORT_UNAVAILABLE"
        }, EXIT_ACTION_FAILED);
      }
      await controller.reconnectForRecovery();
      recoveryReinspection = await runReinspection(
        controller,
        opts,
        selector,
        treeData.target_app,
        selected
      );
    } catch (reinspectionErr) {
      recoveryReinspectionError = {
        code: reinspectionErr.details?.code || reinspectionErr.code || "REINSPECTION_FAILED",
        message: reinspectionErr.message
      };
    }
    err.recoveryContext = {
      inspectionAttempt: inspected.attempt,
      selected,
      beforeValue: match.node.value,
      recoveryTransport: recoveryReinspection
        ? "fresh_mcp_process"
        : "fresh_mcp_process_failed",
      reinspection: recoveryReinspection,
      reinspectionError: recoveryReinspectionError
    };
    throw err;
  }

  return {
    attempt: 1,
    inspectionAttempt: inspected.attempt,
    treeData,
    match,
    selected,
    actionPayload: actionData,
    refs,
    beforeValue: match.node.value
  };
}

async function runReinspection(
  controller,
  opts,
  selector,
  expectedTargetApp,
  expectedTarget = null
) {
  const inspected = await inspectTreeWithRetries(controller, opts, opts.retryLimit);
  const treeData = inspected.treeData;
  const matches = collectSelectorMatches(treeData.tree, selector);
  const match = matches.length === 1 ? matches[0] : null;
  const summaries = match ? {
    role: match.node.role,
    subrole: match.node.subrole,
    identifier: match.node.identifier,
    description: match.node.description,
    title: match.node.title,
    value: match.node.value,
    enabled: match.node.enabled,
    path: match.path,
    advertises_press: Array.isArray(match.node.supported_actions)
      && match.node.supported_actions.includes(SUPPORTED_AX_ACTION),
    has_element_ref: Boolean(match.node.element_ref),
    element_ref_hash: match.node.element_ref
      ? sha256Hex(match.node.element_ref).slice(0, 16)
      : null
  } : null;
  const sameSelectorResolution = matches.length > 1
    ? "ambiguous"
    : treeData.truncated === true
      ? "indeterminate_truncated"
      : matches.length === 1
        ? "unique"
        : "absent";

  return {
    attempt: inspected.attempt,
    treeData,
    match,
    matchCount: matches.length,
    sameSelectorResolution,
    sameTargetProcessFields: Boolean(
      expectedTargetApp
      && treeData.target_app
      && treeData.target_app.pid === expectedTargetApp.pid
      && treeData.target_app.bundle_id === expectedTargetApp.bundle_id
      && treeData.target_app.name === expectedTargetApp.name
    ),
    sameTargetPerceptionInvariant: Boolean(
      expectedTarget
      && match
      && match.path === expectedTarget.path
      && match.node.role === expectedTarget.role
      && match.node.subrole === expectedTarget.subrole
      && (
        expectedTarget.identifier === undefined
        || match.node.identifier === expectedTarget.identifier
      )
    ),
    summaries: summaries ? {
      ...summaries,
      tree_node_count: treeData.node_count,
      tree_max_depth_reached: treeData.max_depth_reached,
      tree_truncated: treeData.truncated,
      topology_version: treeData.topology_version
    } : null,
    observedValue: match?.node.value
  };
}

async function createController(socketPath) {
  if (!fs.existsSync(MCP_CLIENT_PATH) || !fs.existsSync(MCP_STDIO_PATH)) {
    fail("Missing @modelcontextprotocol/sdk dependency in mcp/computer-use-mcp node_modules", {
      clientPath: MCP_CLIENT_PATH,
      stdioPath: MCP_STDIO_PATH
    }, EXIT_USAGE);
  }

  const sdkClient = await import(pathToFileURL(MCP_CLIENT_PATH).href);
  const sdkStdio = await import(pathToFileURL(MCP_STDIO_PATH).href);

  const controller = {
    client: new sdkClient.Client(
      { name: "operator-safe-ax-live-proof", version: "1.0.0" },
      { capabilities: {} }
    ),
    transport: new sdkStdio.StdioClientTransport({
      command: MCP_SERVER_PATH,
      args: [],
      cwd: REPO_ROOT,
      env: {
        ...process.env,
        AGY_SOCKET_PATH: socketPath,
        // This proof lane must not mutate the operator-global mise trust list.
        // The launcher still validates exact ambient Node and pnpm versions.
        TEST_FORCE_MISSING_MISE: "1"
      }
    }),
    reconnectForRecovery: null
  };

  controller.reconnectForRecovery = async () => {
    await closeController(controller);
    const replacement = await createController(socketPath);
    controller.client = replacement.client;
    controller.transport = replacement.transport;
    await controller.client.connect(controller.transport);
  };

  return controller;
}

async function closeController(controller) {
  if (!controller) {
    return;
  }

  if (controller.client && typeof controller.client.close === "function") {
    try {
      await controller.client.close();
    } catch {
      // Intentionally ignore cleanup failures after best-effort close.
    }
  }

  if (controller.transport && typeof controller.transport.close === "function") {
    try {
      await controller.transport.close();
    } catch {
      // Intentionally ignore cleanup failures after best-effort close.
    }
  }
}

async function initializeController(socketPath, factory = createController) {
  const controller = await factory(socketPath);
  if (
    !controller
    || !controller.client
    || !controller.transport
    || typeof controller.reconnectForRecovery !== "function"
  ) {
    fail("Controller factory did not provide the required recovery transport", {
      code: "RECOVERY_TRANSPORT_UNAVAILABLE"
    }, EXIT_ACTION_FAILED);
  }
  await controller.client.connect(controller.transport);
  return controller;
}

function buildReinspectionReceipt(reinspection, opts, beforeValue, effectVerdictOverride = null) {
  const afterValueMatches = opts.afterValue === undefined
    ? null
    : reinspection.matchCount === 1 && reinspection.observedValue === opts.afterValue;
  const effectVerdict = effectVerdictOverride
    || (opts.afterValue === undefined
      ? "not_asserted"
      : reinspection.sameTargetProcessFields
        && reinspection.sameTargetPerceptionInvariant
        && reinspection.sameSelectorResolution === "unique"
        && afterValueMatches
        ? "verified"
        : "failed");

  return {
    tree_node_count: reinspection.treeData.node_count,
    tree_max_depth_reached: reinspection.treeData.max_depth_reached,
    tree_truncated: reinspection.treeData.truncated,
    topology_version_hash: sha256Hex(reinspection.treeData.topology_version).slice(0, 16),
    fresh_app_instance_ref_hash: sha256Hex(reinspection.treeData.app_instance_ref).slice(0, 16),
    same_target_process_fields: reinspection.sameTargetProcessFields,
    process_birth_continuity: "not_exposed_by_ax_tree",
    same_target_perception_invariant: reinspection.sameTargetPerceptionInvariant,
    same_selector_resolution: reinspection.sameSelectorResolution,
    same_selector_match_count: reinspection.matchCount,
    target: reinspection.summaries ? {
      ...reinspection.summaries,
      value: reinspection.observedValue
    } : null,
    before_value_match: opts.beforeValue === undefined ? null : beforeValue === opts.beforeValue,
    after_value_match: afterValueMatches,
    effect_verdict: effectVerdict
  };
}

function assertSuccessfulReinspection(reinspection, opts) {
  if (!reinspection.sameTargetProcessFields) {
    fail("Post-action inspection resolved different target process fields", {
      code: "TARGET_PROCESS_CHANGED"
    }, EXIT_ACTION_FAILED);
  }

  if (opts.afterValue !== undefined && reinspection.sameSelectorResolution !== "unique") {
    fail("Postcondition is unverifiable because the original selector no longer resolves uniquely", {
      expected: opts.afterValue,
      same_selector_resolution: reinspection.sameSelectorResolution,
      same_selector_match_count: reinspection.matchCount,
      code: "AFTER_VALUE_UNVERIFIABLE"
    }, EXIT_ACTION_FAILED);
  }

  if (
    opts.afterValue !== undefined
    && !reinspection.sameTargetPerceptionInvariant
  ) {
    fail("Postcondition is unverifiable because the selector no longer resolves to the original role/path/identifier invariant", {
      code: "AFTER_VALUE_UNVERIFIABLE",
      same_selector_resolution: reinspection.sameSelectorResolution,
      same_target_perception_invariant: false
    }, EXIT_ACTION_FAILED);
  }

  if (opts.afterValue !== undefined && reinspection.observedValue !== opts.afterValue) {
    fail("Postcondition failed: observed after-value does not match expectation", {
      expected: opts.afterValue,
      actual: reinspection.observedValue,
      code: "AFTER_VALUE_MISMATCH"
    }, EXIT_ACTION_FAILED);
  }
}

async function executeSuccessfulPressLifecycle(controller, opts, selector) {
  const pressAttempt = await performPressFlow(controller, opts, selector);
  let reinspection;
  try {
    reinspection = await runReinspection(
      controller,
      opts,
      selector,
      pressAttempt.treeData.target_app,
      pressAttempt.selected
    );
    assertSuccessfulReinspection(reinspection, opts);
  } catch (err) {
    err.completedActionContext = {
      pressAttempt,
      reinspection: reinspection || null,
      reinspectionError: reinspection
        ? null
        : {
            code: err.details?.code || err.code || "REINSPECTION_FAILED",
            message: err.message
          }
    };
    throw err;
  }
  return { pressAttempt, reinspection };
}

async function main() {
  const opts = parseArgs(process.argv);

  const receipt = {
    success: false,
    command: "operator-safe-ax-live-proof",
    socket: opts.socket,
    app_id: opts.appId,
    selector: {
      identifier: opts.identifier,
      description: opts.description,
      title: opts.title,
      value: opts.value
    },
    checks: {
      before_value_expected: opts.beforeValue,
      after_value_expected: opts.afterValue
    },
    retries: {
      retry_limit: opts.retryLimit,
      tool_timeout_ms: opts.toolTimeoutMs,
      inspection_only: true,
      action_retry_policy: "never",
      lease_replay_authority: "native_and_mcp_regression_tests_only"
    },
    attempts: {
      status: null,
      inspection: null,
      action: null,
      reinspect: null
    },
    status_gate: null,
    target: null,
    action: null,
    reinspection: null,
    reinspection_error: null
  };

  let controller = null;

  try {
    // SAFETY GATE 1: explicit socket/app selection prevents implicit frontmost targeting.
    controller = await initializeController(opts.socket);

    receipt.attempts.status = 1;
    const statusGate = await getStatus(controller, opts);
    receipt.status_gate = statusGate;

    const selector = {
      identifier: opts.identifier,
      description: opts.description,
      title: opts.title,
      value: opts.value
    };
    let lifecycle;
    try {
      lifecycle = await executeSuccessfulPressLifecycle(controller, opts, selector);
    } catch (err) {
      const recovery = err.recoveryContext;
      if (recovery) {
        receipt.attempts.inspection = recovery.inspectionAttempt;
        receipt.attempts.action = 1;
        receipt.target = recovery.selected;
        receipt.action = {
          status: "outcome_unknown",
          requested_strategy: "ax_semantic",
          action: SUPPORTED_AX_ACTION,
          requires_reinspection: true,
          global_hid_posts: null,
          settlement: "unknown_action_result",
          recovery_transport: recovery.recoveryTransport
        };
        if (recovery.reinspection) {
          receipt.attempts.reinspect = recovery.reinspection.attempt || 1;
          receipt.reinspection = buildReinspectionReceipt(
            recovery.reinspection,
            opts,
            recovery.beforeValue,
            "unknown"
          );
        }
        receipt.reinspection_error = recovery.reinspectionError;
      }
      const completed = err.completedActionContext;
      if (completed) {
        const completedPress = completed.pressAttempt;
        receipt.attempts.inspection = completedPress.inspectionAttempt;
        receipt.attempts.action = completedPress.attempt;
        receipt.target = completedPress.selected;
        receipt.action = {
          status: completedPress.actionPayload.status,
          strategy: completedPress.actionPayload.strategy,
          action: completedPress.actionPayload.action,
          action_id_hash: sha256Hex(completedPress.actionPayload.action_id || "").slice(0, 16),
          requires_reinspection: completedPress.actionPayload.requires_reinspection,
          global_hid_posts: completedPress.actionPayload.global_hid_posts,
          duration_ms: completedPress.actionPayload.duration_ms,
          settlement: "native_response"
        };
        if (completed.reinspection) {
          receipt.attempts.reinspect = completed.reinspection.attempt || 1;
          receipt.reinspection = buildReinspectionReceipt(
            completed.reinspection,
            opts,
            completedPress.beforeValue
          );
        }
        receipt.reinspection_error = completed.reinspectionError;
      }
      throw err;
    }
    const { pressAttempt, reinspection } = lifecycle;
    receipt.attempts.action = pressAttempt.attempt;
    receipt.attempts.inspection = pressAttempt.inspectionAttempt;
    receipt.target = pressAttempt.selected;
    receipt.action = {
      status: pressAttempt.actionPayload.status,
      strategy: pressAttempt.actionPayload.strategy,
      action: pressAttempt.actionPayload.action,
      action_id_hash: sha256Hex(pressAttempt.actionPayload.action_id || "").slice(0, 16),
      requires_reinspection: pressAttempt.actionPayload.requires_reinspection,
      global_hid_posts: pressAttempt.actionPayload.global_hid_posts,
      duration_ms: pressAttempt.actionPayload.duration_ms,
      settlement: "native_response"
    };

    // SAFETY REQUIREMENT: the integrated lifecycle already completed one fresh
    // same-app inspection before this success receipt is constructed.
    receipt.attempts.reinspect = reinspection.attempt || 1;
    receipt.reinspection = buildReinspectionReceipt(
      reinspection,
      opts,
      pressAttempt.beforeValue
    );
    receipt.success = true;
    console.log(JSON.stringify(receipt, null, 2));
  } catch (err) {
    if (
      err.details?.code === "USER_INTERVENED_RETRY_EXHAUSTED"
      && Array.isArray(err.details.attempts)
    ) {
      receipt.attempts.inspection = err.details.attempts.length;
    }
    const exitCode = Number.isInteger(err.exitCode) ? err.exitCode : EXIT_ACTION_FAILED;
    const finalReceipt = {
      ...receipt,
      success: false,
      error: {
        code: err.details?.code || err.code || "OPERATOR_SAFE_AX_ERROR",
        message: err.message,
        details: err.details || null
      }
    };
    console.log(JSON.stringify(finalReceipt, null, 2));
    process.exit(exitCode);
  } finally {
    await closeController(controller);
  }

  process.exit(EXIT_SUCCESS);
}

export {
  ensureStatusGate,
  executeSuccessfulPressLifecycle,
  initializeController,
  performPressFlow,
  runReinspection
};

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
) {
  main().catch((err) => {
    const exitCode = Number.isInteger(err.exitCode) ? err.exitCode : EXIT_ACTION_FAILED;
    console.log(JSON.stringify({
      success: false,
      command: "operator-safe-ax-live-proof",
      error: {
        code: err.code || "UNHANDLED_ERROR",
        message: err.message
      }
    }, null, 2));
    process.exit(exitCode);
  });
}
