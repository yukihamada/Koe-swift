import { open, showHUD } from "@raycast/api";

export default async function Command() {
  await open("koe://transcribe");
  await showHUD("🎙 Koe: Voice Input Started");
}
