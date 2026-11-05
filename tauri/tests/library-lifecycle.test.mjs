import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import ts from "../node_modules/typescript/lib/typescript.js";

async function actualModule(path) {
  const source = await readFile(new URL(path, import.meta.url), "utf8");
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext },
  });
  return import(`data:text/javascript;base64,${Buffer.from(outputText).toString("base64")}`);
}
const { PlaybackHistoryTracker } = await actualModule("../src/library-state.ts");
const { applySnapshot, initialView, sliderValueAtKey } = await actualModule("../src/player-state.ts");
const { listWindow } = await actualModule("../src/virtual-list.ts");

function playing(path, overrides = {}) {
  return { ...initialView, generation: 1, mediaEpoch: 1, revision: 1, connected: true, ready: true,
    player: { ...initialView.player, idle: false, fileName: "same.mkv", mediaPath: path,
      mediaTitle: "Same", position: 12, duration: 90, ...overrides } };
}

test("late path notification records once even when idle changed before filename and title", () => {
  const tracker = new PlaybackHistoryTracker();
  assert.deepEqual(tracker.accept(playing(""), { ended: false, now: 0 }), []);
  const path = "C:\\Movies\\same.mkv";
  const writes = tracker.accept(playing(path), { ended: false, now: 1 });
  assert.deepEqual(writes, [{ command: "history_record", args: { path, title: "Same" } }]);
  assert.deepEqual(tracker.accept(playing(path, { mediaTitle: "Late title" }), { ended: false, now: 2 }), []);
});

test("start-file and EOF resets preserve the previous complete path and last valid position", () => {
  const tracker = new PlaybackHistoryTracker();
  tracker.accept(playing("/a/same.mkv"), { ended: false, now: 0 });
  tracker.accept(playing("/a/same.mkv", { position: 42 }), { ended: false, now: 1 });
  const next = { ...playing(""), mediaEpoch: 2 };
  assert.deepEqual(tracker.accept(next, { ended: false, now: 2 }), [
    { command: "history_update", args: { path: "/a/same.mkv", position: 42, duration: 90 } },
  ]);
  assert.deepEqual(tracker.accept({ ...playing("/b/same.mkv"), mediaEpoch: 2 }, { ended: false, now: 3 }), [
    { command: "history_record", args: { path: "/b/same.mkv", title: "Same" } },
  ]);
  assert.deepEqual(tracker.accept({ ...playing("/b/same.mkv"), mediaEpoch: 2 }, { ended: true, now: 4 }), [
    { command: "history_update", args: { path: "/b/same.mkv", position: 12, duration: 90 } },
  ]);
  assert.deepEqual(tracker.accept({ ...playing("/b/same.mkv"), mediaEpoch: 2 }, { ended: true, now: 5 }), []);
});

test("progress checkpoints do not increment play counts; disconnect flushes position once", () => {
  const tracker = new PlaybackHistoryTracker();
  tracker.accept(playing("https://example.test/media/same.mkv"), { ended: false, now: 0 });
  const writes = tracker.accept(playing("https://example.test/media/same.mkv", { position: 25 }), { ended: false, now: 5000 });
  assert.equal(writes.length, 1);
  assert.equal(writes[0].command, "history_update");
  assert.equal(writes[0].args.position, 25);
  const disconnected = { ...initialView, generation: 1, mediaEpoch: 1 };
  assert.equal(tracker.accept(disconnected, { ended: false, now: 5001 })[0].args.position, 25);
  assert.deepEqual(tracker.accept(disconnected, { ended: false, now: 5002 }), []);
});

test("snapshot keeps full media identities distinct from identical display names", () => {
  for (const path of ["/a/same.mkv", "/b/same.mkv", "C:\\Movies\\same.mkv", "https://example.test/same.mkv?item=2"]) {
    const view = applySnapshot(initialView, { generation: 1, mediaEpoch: 1, revision: 1,
      connected: true, ready: true, endFile: null, error: null,
      properties: { path, filename: "same.mkv", "idle-active": false } });
    assert.equal(view.player.fileName, "same.mkv");
    assert.equal(view.player.mediaPath, path);
  }
  const missing = applySnapshot(initialView, { generation: 1, mediaEpoch: 1, revision: 1,
    connected: true, ready: true, endFile: null, error: null,
    properties: { filename: "same.mkv" } });
  assert.equal(missing.player.mediaPath, "");
});

test("slider keys adjust and clamp values without capturing unrelated shortcuts", () => {
  assert.equal(sliderValueAtKey("ArrowRight", 128, 0, 130, 5), 130);
  assert.equal(sliderValueAtKey("ArrowDown", 2, 0, 130, 5), 0);
  assert.equal(sliderValueAtKey("Home", 60, 0, 130, 5), 0);
  assert.equal(sliderValueAtKey("End", 60, 0, 130, 5), 130);
  assert.equal(sliderValueAtKey(" ", 60, 0, 130, 5), null);
  assert.equal(sliderValueAtKey("ArrowUp", NaN, 0, 130, 5), null);
});

test("large directories render a bounded window through the last row", () => {
  assert.deepEqual(listWindow(0, 0, 500, 34), { start: 0, end: 0 });
  assert.deepEqual(listWindow(3, 0, 500, 34), { start: 0, end: 3 });
  for (const top of [0, 1000, 100000, 339500]) {
    const { start, end } = listWindow(10000, top, 500, 34);
    assert.ok(end - start <= 28);
    assert.ok(start >= 0 && end <= 10000);
  }
  assert.equal(listWindow(10000, 339500, 500, 34).end, 10000);
});

test("unavailable position before EOF never overwrites the last valid checkpoint", () => {
  const tracker = new PlaybackHistoryTracker();
  tracker.accept(playing("/a/same.mkv", { position: 42 }), { now: 0 });
  tracker.accept(playing("/a/same.mkv", { position: 0 }), { now: 1, hasPosition: false });
  const writes = tracker.accept(playing("/a/same.mkv", { position: 0 }), { now: 2, ended: true, hasPosition: false });
  assert.equal(writes[0].args.position, 42);
});
