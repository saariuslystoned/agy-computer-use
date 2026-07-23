// surface.mjs — bring Vysor frontmost (journaled env prep), capture its AX
// window bounds, and take a fresh observe. Still no phone-side input.
import { execSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import path from "node:path";

const VYSOR_BUNDLE = "com.electron.vysor";

export default async function run(cu) {
  cu.journal({ kind: "env_prep", action: "open -b com.electron.vysor", rationale: "surface hidden Vysor window before mirror targeting; desktop-level app activation only" });
  execSync(`open -b ${VYSOR_BUNDLE}`);
  await new Promise((r) => setTimeout(r, 1500));

  const ax = await cu.call("computer_use_ax_tree", { app_id: VYSOR_BUNDLE, max_depth: 6 });
  const windows = [];
  const walk = (n, depth) => {
    if (!n) return;
    if (n.role === "AXWindow") windows.push({ title: n.title ?? "", bounds: n.bounds, children: (n.children ?? []).map((c) => ({ role: c.role, title: c.title ?? "", bounds: c.bounds })) });
    for (const c of n.children ?? []) walk(c, depth + 1);
  };
  walk(ax.structured.tree, 0);
  writeFileSync(path.join(cu.runDir, "vysor_ax_windows.json"), JSON.stringify(windows, null, 2));
  cu.journal({ kind: "note", vysor_windows: windows.map((w) => ({ title: w.title, bounds: w.bounds })) });

  await cu.observe();
}
