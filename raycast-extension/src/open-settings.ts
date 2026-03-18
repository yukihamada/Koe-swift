import { open, showHUD } from "@raycast/api";

export default async function Command() {
  await open("koe://settings");
  await showHUD("⚙️ Koe: Opening Settings");
}
