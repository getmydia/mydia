import assert from "node:assert/strict";
import test from "node:test";

import {
  SKIPPABLE_ERRORS,
  createTrailerQueue,
  loadYouTubeApi,
  resetYouTubeApiForTest,
} from "../../js/hooks/trailer_player.mjs";

test("region and embed errors are skippable, unknown codes are not", () => {
  for (const code of [2, 5, 100, 101, 150]) assert.ok(SKIPPABLE_ERRORS.has(code));
  assert.ok(!SKIPPABLE_ERRORS.has(999));
});

test("a skippable failure advances to the next key", () => {
  const queue = createTrailerQueue(3);
  assert.equal(queue.current(), 0);
  assert.equal(queue.fail(150), 1);
  assert.equal(queue.current(), 1);
});

test("an unknown error code stays put", () => {
  const queue = createTrailerQueue(3);
  assert.equal(queue.fail(999), 0);
  assert.equal(queue.current(), 0);
});

test("failures wrap around and skip keys that already failed", () => {
  const queue = createTrailerQueue(3);
  queue.select(2);
  assert.equal(queue.fail(101), 0);
  assert.equal(queue.fail(101), 1);
});

test("returns null once every key has failed", () => {
  const queue = createTrailerQueue(2);
  assert.equal(queue.fail(150), 1);
  assert.equal(queue.fail(150), null);
});

test("selecting a failed key by hand re-arms it", () => {
  const queue = createTrailerQueue(2);
  queue.fail(150);
  queue.fail(150);
  queue.select(0);
  assert.equal(queue.current(), 0);
  assert.equal(queue.fail(150), null);
});

function fakeDom() {
  const appended = [];
  const doc = {
    createElement: () => ({}),
    head: { appendChild: (el) => appended.push(el) },
  };
  return { doc, appended };
}

test("loadYouTubeApi resolves immediately when YT is already present", async () => {
  resetYouTubeApiForTest();
  const YT = { Player: function () {} };
  const { doc, appended } = fakeDom();
  assert.equal(await loadYouTubeApi({ YT }, doc), YT);
  assert.equal(appended.length, 0);
});

test("loadYouTubeApi injects the script once and chains the ready callback", async () => {
  resetYouTubeApiForTest();
  let previousCalled = false;
  const win = { onYouTubeIframeAPIReady: () => (previousCalled = true) };
  const { doc, appended } = fakeDom();

  const first = loadYouTubeApi(win, doc);
  const second = loadYouTubeApi(win, doc);
  assert.equal(appended.length, 1);
  assert.equal(appended[0].src, "https://www.youtube.com/iframe_api");

  win.YT = { Player: function () {} };
  win.onYouTubeIframeAPIReady();

  assert.equal(await first, win.YT);
  assert.equal(await second, win.YT);
  assert.ok(previousCalled);
});

test("loadYouTubeApi rejects on script error and allows a retry", async () => {
  resetYouTubeApiForTest();
  const win = {};
  const { doc, appended } = fakeDom();

  const attempt = loadYouTubeApi(win, doc);
  appended[0].onerror();
  await assert.rejects(attempt);

  loadYouTubeApi(win, doc);
  assert.equal(appended.length, 2);
});
