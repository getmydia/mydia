import assert from "node:assert/strict";
import test from "node:test";

import FlashAutoDismiss, {
  createDismissTimer,
} from "../../js/hooks/flash_auto_dismiss.mjs";

// A manual clock: timers fire only when advance() passes their deadline.
function fakeClock() {
  let time = 0;
  let nextId = 1;
  const timers = new Map();

  return {
    now: () => time,
    setTimer(fn, ms) {
      const id = nextId++;
      timers.set(id, { fn, at: time + ms });
      return id;
    },
    clearTimer(id) {
      timers.delete(id);
    },
    advance(ms) {
      time += ms;
      for (const [id, t] of [...timers]) {
        if (t.at <= time) {
          timers.delete(id);
          t.fn();
        }
      }
    },
    pending: () => timers.size,
  };
}

function timerWith(clock, duration, onExpire) {
  return createDismissTimer({
    duration,
    onExpire,
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  });
}

test("expires after the duration", () => {
  const clock = fakeClock();
  let fired = 0;
  const timer = timerWith(clock, 5000, () => fired++);

  timer.start();
  clock.advance(4999);
  assert.equal(fired, 0);
  clock.advance(1);
  assert.equal(fired, 1);
});

test("pause keeps the remaining time and resume continues from it", () => {
  const clock = fakeClock();
  let fired = 0;
  const timer = timerWith(clock, 10000, () => fired++);

  timer.start();
  clock.advance(4000);
  timer.pause();
  assert.equal(timer.remaining(), 6000);

  clock.advance(60000);
  assert.equal(fired, 0);

  timer.resume();
  clock.advance(5999);
  assert.equal(fired, 0);
  clock.advance(1);
  assert.equal(fired, 1);
});

test("start restarts the full duration", () => {
  const clock = fakeClock();
  let fired = 0;
  const timer = timerWith(clock, 5000, () => fired++);

  timer.start();
  clock.advance(4000);
  timer.start();
  clock.advance(4000);
  assert.equal(fired, 0);
  clock.advance(1000);
  assert.equal(fired, 1);
});

test("pause twice and resume while running are no-ops", () => {
  const clock = fakeClock();
  let fired = 0;
  const timer = timerWith(clock, 5000, () => fired++);

  timer.start();
  timer.resume();
  assert.equal(clock.pending(), 1);
  clock.advance(1000);
  timer.pause();
  clock.advance(1000);
  timer.pause();
  assert.equal(timer.remaining(), 4000);
});

test("cancel prevents expiry", () => {
  const clock = fakeClock();
  let fired = 0;
  const timer = timerWith(clock, 5000, () => fired++);

  timer.start();
  timer.cancel();
  clock.advance(10000);
  assert.equal(fired, 0);
  assert.equal(clock.pending(), 0);
});

// Minimal element stand-in for the hook tests.
function fakeElement({ dismissAfter, text, click = "[[\"push\",{}]]" }) {
  const listeners = new Map();
  const attrs = { "data-dismiss-after": dismissAfter, "phx-click": click };

  return {
    textContent: text,
    getAttribute: (name) => attrs[name] ?? null,
    addEventListener: (type, fn) => listeners.set(type, fn),
    removeEventListener: (type) => listeners.delete(type),
    dispatch: (type) => listeners.get(type)?.(),
    listenerCount: () => listeners.size,
  };
}

function mountHook(el, clock) {
  const executed = [];
  const hook = Object.create(FlashAutoDismiss);
  hook.el = el;
  hook.liveSocket = { execJS: (target, js) => executed.push([target, js]) };
  hook.clock = clock;
  hook.mounted();
  return { hook, executed };
}

test("hook runs the element's phx-click when the timer expires", () => {
  const clock = fakeClock();
  const el = fakeElement({ dismissAfter: "5000", text: "Saved" });
  const { executed } = mountHook(el, clock);

  clock.advance(5000);
  assert.deepEqual(executed, [[el, el.getAttribute("phx-click")]]);
});

test("hook without data-dismiss-after never expires", () => {
  const clock = fakeClock();
  const el = fakeElement({ dismissAfter: null, text: "Reconnecting" });
  const { executed } = mountHook(el, clock);

  clock.advance(60000);
  assert.equal(executed.length, 0);
  assert.equal(clock.pending(), 0);
});

test("hover pauses and leaving resumes", () => {
  const clock = fakeClock();
  const el = fakeElement({ dismissAfter: "5000", text: "Saved" });
  const { executed } = mountHook(el, clock);

  clock.advance(3000);
  el.dispatch("mouseenter");
  clock.advance(30000);
  assert.equal(executed.length, 0);

  el.dispatch("mouseleave");
  clock.advance(2000);
  assert.equal(executed.length, 1);
});

test("updated with new text restarts, unchanged text does not", () => {
  const clock = fakeClock();
  const el = fakeElement({ dismissAfter: "10000", text: "Connection failed: a" });
  const { hook, executed } = mountHook(el, clock);

  clock.advance(8000);
  hook.updated();
  clock.advance(2000);
  assert.equal(executed.length, 1, "unchanged text keeps the original deadline");

  const el2 = fakeElement({ dismissAfter: "10000", text: "Connection failed: a" });
  const second = mountHook(el2, clock);
  clock.advance(8000);
  el2.textContent = "Connection failed: b";
  second.hook.updated();
  clock.advance(2000);
  assert.equal(second.executed.length, 0, "new text restarts the full timer");
  clock.advance(8000);
  assert.equal(second.executed.length, 1);
});

test("focus pauses and leaving focus resumes", () => {
  const clock = fakeClock();
  const el = fakeElement({ dismissAfter: "5000", text: "Saved" });
  const { executed } = mountHook(el, clock);

  clock.advance(3000);
  el.dispatch("focusin");
  clock.advance(30000);
  assert.equal(executed.length, 0);

  el.dispatch("focusout");
  clock.advance(2000);
  assert.equal(executed.length, 1);
});

test("pointer leaving while focus remains keeps the toast paused", () => {
  const clock = fakeClock();
  const el = fakeElement({ dismissAfter: "5000", text: "Saved" });
  const { executed } = mountHook(el, clock);

  el.dispatch("mouseenter");
  el.dispatch("focusin");
  el.dispatch("mouseleave");
  clock.advance(30000);
  assert.equal(executed.length, 0, "focused toast must not vanish");

  el.dispatch("focusout");
  clock.advance(5000);
  assert.equal(executed.length, 1);
});

test("focus leaving while the pointer remains keeps the toast paused", () => {
  const clock = fakeClock();
  const el = fakeElement({ dismissAfter: "5000", text: "Saved" });
  const { executed } = mountHook(el, clock);

  el.dispatch("focusin");
  el.dispatch("mouseenter");
  el.dispatch("focusout");
  clock.advance(30000);
  assert.equal(executed.length, 0, "hovered toast must not vanish");

  el.dispatch("mouseleave");
  clock.advance(5000);
  assert.equal(executed.length, 1);
});

test("a message change while hovered stays paused until the pointer leaves", () => {
  const clock = fakeClock();
  const el = fakeElement({ dismissAfter: "5000", text: "Saved" });
  const { hook, executed } = mountHook(el, clock);

  el.dispatch("mouseenter");
  el.textContent = "Saved again";
  hook.updated();
  clock.advance(30000);
  assert.equal(executed.length, 0, "held toast must not vanish under the cursor");

  el.dispatch("mouseleave");
  clock.advance(5000);
  assert.equal(executed.length, 1);
});

test("destroyed cancels the timer and removes listeners", () => {
  const clock = fakeClock();
  const el = fakeElement({ dismissAfter: "5000", text: "Saved" });
  const { hook, executed } = mountHook(el, clock);

  hook.destroyed();
  clock.advance(10000);
  assert.equal(executed.length, 0);
  assert.equal(el.listenerCount(), 0);
});
