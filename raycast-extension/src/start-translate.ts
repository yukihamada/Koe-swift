import { open, showHUD } from "@raycast/api";

export default async function Command() {
  await open("koe://translate");
  await showHUD("🔤 Koe: Translation Mode Started");
}
