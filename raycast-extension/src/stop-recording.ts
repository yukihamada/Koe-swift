import { open, showHUD } from "@raycast/api";

export default async function Command() {
  await open("koe://stop");
  await showHUD("⏹ Koe: Recording Stopped");
}
