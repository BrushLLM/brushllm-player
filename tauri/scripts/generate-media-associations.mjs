import { readFileSync, writeFileSync } from "node:fs";

const manifest = JSON.parse(readFileSync(new URL("../../shared/media-formats.json", import.meta.url), "utf8"));
const extensions = [...manifest.video, ...manifest.audio, ...manifest.playlist].sort();
if (extensions.some((extension) => !/^[a-z0-9]+$/.test(extension))
    || new Set(extensions).size !== extensions.length) {
  throw new Error("Media extensions must be unique and contain only lowercase letters or digits");
}

const lines = [
  "!macro ForEachPlayerExtension macro",
  ...extensions.map((extension) => '  !insertmacro ${macro} "' + extension + '"'),
  "!macroend",
  "",
];
writeFileSync(new URL("../src-tauri/installer/media-extensions.nsh", import.meta.url), lines.join("\n"));
