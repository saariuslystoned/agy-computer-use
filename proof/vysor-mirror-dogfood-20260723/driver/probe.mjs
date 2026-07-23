// probe.mjs — read-only recon: status, Vysor AX bounds, full-desktop observe.
// No input synthesis. Used to derive the Vysor window rect and mirror content rect.
const VYSOR_BUNDLE = process.env.VYSOR_BUNDLE_ID || "com.vysor.app";

export default async function run(cu) {
  const status = await cu.status();
  const s = status.structured;
  if (s.tcc_permission_state !== "granted" || s.input_mutation_state !== "enabled") {
    throw new Error(`host not ready: tcc=${s.tcc_permission_state} input=${s.input_mutation_state}`);
  }
  cu.journal({ kind: "note", displays: s.topology.displays });

  try {
    const ax = await cu.call("computer_use_ax_tree", { app_id: VYSOR_BUNDLE, max_depth: 4 });
    cu.journal({ kind: "note", vysor_ax: "ok", target_app: ax.structured.target_app });
  } catch (e) {
    cu.journal({ kind: "note", vysor_ax_failed: String(e).slice(0, 300) });
  }

  await cu.observe();
}
