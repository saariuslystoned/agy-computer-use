// open-mirror.mjs — observe, click the Vysor device-card play button to open
// the Pixel 10_Pro_XL mirror window, re-observe, dump AX windows.
import { writeFileSync } from "node:fs";
import path from "node:path";

export default async function run(cu) {
  await cu.observe();
  const { capture_id, topology_version } = cu.lastCapture;
  await cu.call("computer_use_click", {
    capture_id,
    topology_version,
    x: Number(process.env.CLICK_NX),
    y: Number(process.env.CLICK_NY),
    intent: "Open Vysor mirror window for registered swarm test device Pixel 10_Pro_XL (pixel10_xl_sender) via device-card play button",
  });
  await new Promise((r) => setTimeout(r, 3000));
  await cu.observe();

  const ax = await cu.call("computer_use_ax_tree", { app_id: "com.electron.vysor", max_depth: 4 });
  const windows = [];
  const walk = (n) => {
    if (!n) return;
    if (n.role === "AXWindow") windows.push({ title: n.title ?? "", bounds: n.bounds });
    for (const c of n.children ?? []) walk(c);
  };
  walk(ax.structured.tree);
  writeFileSync(path.join(cu.runDir, "vysor_ax_windows_after.json"), JSON.stringify(windows, null, 2));
  cu.journal({ kind: "note", vysor_windows_after: windows });
}
