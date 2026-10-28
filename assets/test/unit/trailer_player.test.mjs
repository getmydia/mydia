import assert from "node:assert/strict";
import test from "node:test";

import TrailerPlayer, {
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
  assert.equal(queue.fail(150), 1);
  queue.select(0);
  queue.select(1);
  // Key 0 is playable again; without the re-arm this would be null.
  assert.equal(queue.fail(150), 0);
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

  const timers = { setTimeout: () => 0, clearTimeout() {} };

  const attempt = loadYouTubeApi(win, doc, timers);
  appended[0].onerror();
  await assert.rejects(attempt);

  loadYouTubeApi(win, doc, timers);
  assert.equal(appended.length, 2);
});

test("loadYouTubeApi times out when the ready callback never fires, then retries", async () => {
  resetYouTubeApiForTest();
  const win = {};
  const { doc, appended } = fakeDom();
  let fire;
  const timers = { setTimeout: (fn) => (fire = fn), clearTimeout() {} };

  const attempt = loadYouTubeApi(win, doc, timers, 50);
  fire();
  await assert.rejects(attempt);

  // A late ready callback is harmless.
  win.YT = { Player: function () {} };
  win.onYouTubeIframeAPIReady();

  // apiPromise was reset, but YT is now present, so reset it to prove retry injects again.
  delete win.YT;
  loadYouTubeApi(win, doc, timers, 50);
  assert.equal(appended.length, 2);
});

test("a switcher click before the API loads survives the player creation", async () => {
  resetYouTubeApiForTest();
  const created = [];
  const YT = {
    Player: function (target, options) {
      created.push(options);
      this.destroy = () => {};
    },
  };
  const savedWindow = globalThis.window;
  const savedDocument = globalThis.document;
  const appended = [];
  globalThis.window = {};
  globalThis.document = {
    createElement: () => ({}),
    head: { appendChild: (el) => appended.push(el) },
  };

  try {
    let clickHandler;
    const mountNode = { replaceChildren() {}, classList: { add() {}, remove() {} } };
    const button = {
      dataset: { index: "1" },
      classList: { toggle() {} },
      setAttribute() {},
    };
    const el = {
      dataset: { keys: JSON.stringify(["aaa", "bbb"]), autoplay: "false" },
      querySelector: (sel) => (sel === '[data-role="player"]' ? mountNode : null),
      querySelectorAll: () => [button],
      addEventListener: (_type, handler) => (clickHandler = handler),
      removeEventListener() {},
      contains: () => true,
    };
    const hook = { ...TrailerPlayer, el };
    hook.mounted();

    clickHandler({ target: { closest: () => button } });
    globalThis.window.YT = YT;
    globalThis.window.onYouTubeIframeAPIReady();
    await new Promise((resolve) => setImmediate(resolve));

    assert.equal(created.length, 1);
    assert.equal(created[0].videoId, "bbb");
    assert.equal(created[0].playerVars.autoplay, 1);
  } finally {
    globalThis.window = savedWindow;
    globalThis.document = savedDocument;
  }
});

function mountWithFakePlayer({ autoplay }) {
  resetYouTubeApiForTest();
  const calls = [];
  let onError;
  let onStateChange;
  const YT = {
    Player: function (_target, options) {
      onError = options.events.onError;
      onStateChange = options.events.onStateChange;
      this.loadVideoById = (key) => calls.push(["load", key]);
      this.cueVideoById = (key) => calls.push(["cue", key]);
      this.destroy = () => {};
    },
  };
  const hidden = new Set(["hidden"]);
  const unavailable = {
    classList: {
      add: (c) => hidden.add(c),
      remove: (c) => hidden.delete(c),
    },
  };
  const mountNode = { replaceChildren() {}, classList: { add() {}, remove() {} } };
  const buttons = ["0", "1"].map((index) => {
    const classes = new Set(index === "0" ? ["btn-primary"] : ["btn-ghost"]);
    return {
      dataset: { index },
      attrs: {},
      classes,
      setAttribute(name, value) {
        this.attrs[name] = value;
      },
      classList: {
        toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)),
      },
    };
  });
  const el = {
    dataset: { keys: JSON.stringify(["aaa", "bbb"]), autoplay: String(autoplay) },
    querySelector: (sel) =>
      sel === '[data-role="player"]' ? mountNode : sel === '[data-role="unavailable"]' ? unavailable : null,
    querySelectorAll: () => buttons,
    addEventListener() {},
    removeEventListener() {},
    contains: () => true,
  };
  const saved = { window: globalThis.window, document: globalThis.document };
  globalThis.window = { YT };
  globalThis.document = { createElement: () => ({}), head: { appendChild() {} } };
  const hook = { ...TrailerPlayer, el };
  hook.mounted();
  return {
    calls,
    hidden,
    buttons,
    fire: (code) => onError({ data: code }),
    state: (data) => onStateChange({ data }),
    destroy: () => hook.destroyed(),
    ready: () => new Promise((resolve) => setImmediate(resolve)),
    restore: () => Object.assign(globalThis, saved),
  };
}

test("hook falls back on a skippable error, shows unavailable once all failed", async () => {
  const t = mountWithFakePlayer({ autoplay: true });
  try {
    await t.ready();
    t.fire(150);
    assert.deepEqual(t.calls, [["load", "bbb"]]);
    assert.deepEqual(t.buttons.map((b) => b.attrs["aria-pressed"]), ["false", "true"]);
    assert.ok(t.buttons[1].classes.has("btn-primary") && !t.buttons[1].classes.has("btn-ghost"));
    assert.ok(t.buttons[0].classes.has("btn-ghost") && !t.buttons[0].classes.has("btn-primary"));
    assert.ok(t.hidden.has("hidden"));
    t.fire(150);
    assert.ok(!t.hidden.has("hidden"));
  } finally {
    t.restore();
  }
});

test("hook cues instead of loading when autoplay is off", async () => {
  const t = mountWithFakePlayer({ autoplay: false });
  try {
    await t.ready();
    t.fire(150);
    assert.deepEqual(t.calls, [["cue", "bbb"]]);
  } finally {
    t.restore();
  }
});

test("hook loads instead of cueing once the viewer started playback", async () => {
  const t = mountWithFakePlayer({ autoplay: false });
  try {
    await t.ready();
    t.state(1);
    t.fire(150);
    assert.deepEqual(t.calls, [["load", "bbb"]]);
  } finally {
    t.restore();
  }
});

test("a queued error after destroy does nothing", async () => {
  const t = mountWithFakePlayer({ autoplay: true });
  try {
    await t.ready();
    t.destroy();
    t.fire(150);
    assert.deepEqual(t.calls, []);
    assert.ok(t.hidden.has("hidden"));
    assert.deepEqual(t.buttons.map((b) => b.attrs["aria-pressed"]), [undefined, undefined]);
  } finally {
    t.restore();
  }
});

test("hook leaves YouTube's error screen alone for an unknown code", async () => {
  const t = mountWithFakePlayer({ autoplay: true });
  try {
    await t.ready();
    t.fire(999);
    assert.deepEqual(t.calls, []);
    assert.ok(t.hidden.has("hidden"));
  } finally {
    t.restore();
  }
});
