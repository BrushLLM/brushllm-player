import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import ts from "../node_modules/typescript/lib/typescript.js";

// Compile the actual dependency-free frontend reducer/geometry with the
// project's existing TypeScript, not a copied implementation or new runner.
const source = await readFile(new URL("../src/player-state.ts", import.meta.url), "utf8");
const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext } });
const { applySnapshot, CommandGate, initialView, sameMedia, trackFraction, volumeAtClick, commandError } =
  await import(`data:text/javascript;base64,${Buffer.from(compiled.outputText).toString("base64")}`);
const snapshot = (overrides = {}) => ({
  generation: 1, mediaEpoch: 1, revision: 12, connected: true, ready: true, error: null, endFile: null,
  properties: {
    pause: false, "time-pos": 3.5, duration: 10, "idle-active": false,
    "media-title": "Synthetic media", filename: "test.wav", volume: 65, mute: false,
    speed: 1.25, "playlist-count": 2, "playlist-pos": 1,
  }, ...overrides,
});

test("delayed startup or refresh recovers all eleven properties from snapshot", () => {
  const next = applySnapshot(initialView, snapshot());
  assert.deepEqual(next.player, {
    paused: false, position: 3.5, duration: 10, idle: false,
    mediaTitle: "Synthetic media", fileName: "test.wav", volume: 65, muted: false,
    speed: 1.25, playlistCount: 2, playlistPos: 1,
  });
  assert.equal(next.ready, true);
});

test("events before invoke snapshot and out-of-order events never rewind state", () => {
  const event = applySnapshot(initialView, snapshot({ revision: 20 }));
  assert.equal(applySnapshot(event, snapshot({ revision: 12 })), event);
  assert.equal(applySnapshot(event, snapshot({ revision: 20 })), event);
  assert.equal(applySnapshot(event, snapshot({ revision: 21 })).revision, 21);
});

test("reconnect accepts a lower revision but rejects every old generation", () => {
  const old = applySnapshot(initialView, snapshot({ revision: 100 }));
  const reconnected = applySnapshot(old, snapshot({ generation: 2, revision: 1, ready: false, properties: {} }));
  assert.equal(reconnected.player.duration, 0);
  assert.equal(reconnected.player.playlistCount, 0);
  assert.equal(reconnected.player.idle, true);
  assert.equal(applySnapshot(reconnected, snapshot({ generation: 1, revision: 999 })), reconnected);
});

test("EOF clears old playback state and string load errors remain visible while idle", () => {
  const playing = applySnapshot(initialView, snapshot());
  const next = applySnapshot(playing, snapshot({
    revision: 13, connected: false, ready: false,
    endFile: { reason: "error", file_error: "loading failed" },
  }));
  assert.equal(next.player.idle, true);
  assert.equal(next.player.duration, 0);
  assert.equal(next.ready, false);
  assert.equal(next.error, "loading failed");
});

test("normal EOF, stop and quit are not playback errors; later successful load recovers", () => {
  for (const reason of ["eof", "stop", "quit"]) {
    const next = applySnapshot(initialView, snapshot({ endFile: { reason, file_error: null } }));
    assert.equal(next.error, null);
  }
  const failed = applySnapshot(initialView, snapshot({ error: "loading failed" }));
  assert.equal(applySnapshot(failed, snapshot({ revision: 13 })).error, null);
});

test("unavailable properties reset to safe defaults without NaN", () => {
  const next = applySnapshot(initialView, snapshot({ properties: {
    pause: null, duration: null, "time-pos": "NaN", speed: Number.NaN,
    volume: Number.POSITIVE_INFINITY, "playlist-pos": null,
  } }));
  assert.equal(next.player.paused, true);
  assert.equal(next.player.duration, 0);
  assert.equal(next.player.position, 0);
  assert.equal(next.player.speed, 1);
  assert.equal(next.player.volume, 100);
  assert.equal(next.player.playlistPos, -1);
});

test("volume uses currentTarget for fill and background at 0/65/100/130", () => {
  const fullTrack = { getBoundingClientRect: () => ({ left: 20, width: 62 }) };
  for (const volume of [0, 65, 100, 130]) {
    for (const target of [fullTrack, { getBoundingClientRect: () => ({ left: 20, width: 62 * volume / 130 }) }]) {
      assert.equal(volumeAtClick({ clientX: 51, currentTarget: fullTrack, target }), 65);
    }
  }
});

test("volume clamps outside clicks and ignores zero/non-finite widths", () => {
  const event = (clientX, width = 62) => ({ clientX, currentTarget: { getBoundingClientRect: () => ({ left: 20, width }) } });
  assert.equal(volumeAtClick(event(-10)), 0);
  assert.equal(volumeAtClick(event(200)), 130);
  assert.equal(volumeAtClick(event(30, 0)), null);
  assert.equal(volumeAtClick(event(30, Number.NaN)), null);
  assert.equal(trackFraction(Number.NaN, 0, 1), null);
});

test("same-connection start-file invalidates a drag captured for the previous media", () => {
  const mediaA = applySnapshot(initialView, snapshot());
  const drag = { generation: mediaA.generation, mediaEpoch: mediaA.mediaEpoch };
  assert.equal(sameMedia(drag, mediaA), true);
  const mediaB = applySnapshot(mediaA, snapshot({ revision: 13, mediaEpoch: 2, properties: { duration: 100 } }));
  assert.equal(mediaB.generation, mediaA.generation);
  assert.equal(sameMedia(drag, mediaB), false);
  const seeks = [];
  if (sameMedia(drag, mediaB)) seeks.push(mediaA.player.duration / 2);
  assert.deepEqual(seeks, []);
});

test("late failure A cannot overwrite later successful command B on the same connection", async () => {
  const gate = new CommandGate();
  let error = null;
  let rejectA;
  const pendingA = new Promise((_, reject) => { rejectA = reject; });
  const requestA = gate.begin();
  const completionA = pendingA.catch((failure) => {
    if (gate.accepts(requestA)) error = failure;
  });
  const requestB = gate.begin();
  await Promise.resolve("success B");
  if (gate.accepts(requestB)) error = null;
  rejectA("late failure A");
  await completionA;
  assert.equal(error, null);
  assert.equal(gate.accepts(requestA), false);
  assert.equal(gate.accepts(requestB), true);
});

test("new media clears an old command error and invalidates pending failures", () => {
  const gate = new CommandGate();
  const request = gate.begin();
  let error = "command A failed";
  const mediaA = applySnapshot(initialView, snapshot());
  const mediaB = applySnapshot(mediaA, snapshot({ revision: 13, mediaEpoch: 2 }));
  if (!sameMedia(mediaA, mediaB)) { gate.invalidate(); error = null; }
  if (gate.accepts(request)) error = "late A failure";
  assert.equal(error, null);
  assert.equal(gate.accepts(request), false);
});

test("invoke rejections retain backend generation and actionable message", () => {
  assert.deepEqual(commandError({ generation: 3, message: "mpv command failed: property not found" }),
    { generation: 3, message: "mpv command failed: property not found" });
  assert.deepEqual(commandError("IPC disconnected"), { message: "IPC disconnected" });
  assert.equal(commandError(new Error("Timeout")).message, "Timeout");
});

// The project intentionally has no DOM test runner. Keep this contract check
// dependency-free while ensuring the user-facing About surface stays complete.
test("About surface exposes version, license, links, and accessible close paths", async () => {
  const appSource = await readFile(new URL("../src/App.tsx", import.meta.url), "utf8");
  const styles = await readFile(new URL("../src/index.css", import.meta.url), "utf8");
  const packageJson = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));

  assert.match(appSource, /getVersion/);
  assert.match(appSource, /Version \{versionLoading \? "Loading…" : appVersion \?\? "Unavailable"\}/);
  assert.doesNotMatch(appSource, new RegExp(`Version ${packageJson.version.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\\\$&")}`));
  assert.match(appSource, /aria-label="About BrushLLM Player"/);
  assert.match(appSource, /role="dialog"/);
  assert.match(appSource, /aria-modal="true"/);
  assert.match(appSource, /event\.key === "Escape"/);
  assert.match(appSource, /Powered by mpv/);
  assert.match(appSource, /GPL v3/);
  assert.ok(appSource.includes("https://github.com/BrushLLM/brushllm-player"));
  assert.ok(appSource.includes("https://github.com/BrushLLM/brushllm-player/releases"));
  assert.match(appSource, /openUrl as openExternal/);
  assert.doesNotMatch(appSource, /window\.open\(GITHUB/);
  assert.match(appSource, /Full license/);
  assert.match(appSource, /event\.key === "Tab"/);
  assert.match(styles, /\.about-overlay/);
  assert.match(styles, /\.about-dialog/);
  assert.match(styles, /\.about-trigger/);
});
