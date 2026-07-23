// app-drawer.mjs — swipe up inside the Vysor mirror (phone app-drawer gesture),
// then re-observe. Coordinates derived from mirror content rect calibration:
// content rect points x 704..1098, y 66..949 mapping phone 1080x2404.
export default async function run(cu) {
  await cu.observe();
  const { capture_id, topology_version } = cu.lastCapture;
  await cu.call("computer_use_drag", {
    capture_id,
    topology_version,
    start_x: 469,
    start_y: 707,
    end_x: 469,
    end_y: 299,
    intent: "Swipe up inside Vysor mirror content to open the Pixel 10_Pro_XL app drawer (read-only navigation on registered test device)",
  });
  await new Promise((r) => setTimeout(r, 2000));
  await cu.observe();
}
