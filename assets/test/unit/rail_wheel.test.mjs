import assert from "node:assert/strict";
import test from "node:test";

import { decide, LINE_PX, QUIET_MS } from "../../js/hooks/rail_wheel.mjs";

// A rail 400px wide holding 1000px of cards, scrolled to the middle.
const MID = { scrollLeft: 300, scrollWidth: 1000, clientWidth: 400 };
const NOW = 10_000;
const LONG_AGO = -Infinity;

const wheel = (overrides = {}) => ({
  deltaX: 0,
  deltaY: 100,
  deltaMode: 0,
  ctrlKey: false,
  ...overrides,
});

test("scrolls the rail by deltaY when nothing guards against it", () => {
  assert.deepEqual(decide(wheel(), MID, NOW, LONG_AGO), { action: "rail", px: 100 });
  assert.deepEqual(decide(wheel({ deltaY: -100 }), MID, NOW, LONG_AGO), {
    action: "rail",
    px: -100,
  });
});

test("leaves horizontal gestures to the browser", () => {
  assert.deepEqual(decide(wheel({ deltaX: 40, deltaY: 10 }), MID, NOW, LONG_AGO), {
    action: "native",
  });
  assert.deepEqual(decide(wheel({ deltaX: 50, deltaY: 50 }), MID, NOW, LONG_AGO), {
    action: "native",
  });
});

test("leaves pinch-zoom to the browser", () => {
  assert.deepEqual(decide(wheel({ ctrlKey: true }), MID, NOW, LONG_AGO), { action: "native" });
});

test("hands the wheel to the page while a page scroll is under way", () => {
  assert.deepEqual(decide(wheel(), MID, NOW, NOW - (QUIET_MS - 1)), { action: "page" });
});

test("takes the wheel once the page has been quiet for the window", () => {
  assert.deepEqual(decide(wheel(), MID, NOW, NOW - QUIET_MS), { action: "rail", px: 100 });
});

test("passes to the page when the rail does not overflow", () => {
  const fits = { scrollLeft: 0, scrollWidth: 401, clientWidth: 400 };
  assert.deepEqual(decide(wheel(), fits, NOW, LONG_AGO), { action: "page" });
});

test("passes to the page at the start when scrolling back", () => {
  const start = { ...MID, scrollLeft: 1 };
  assert.deepEqual(decide(wheel({ deltaY: -100 }), start, NOW, LONG_AGO), { action: "page" });
  assert.deepEqual(decide(wheel({ deltaY: 100 }), start, NOW, LONG_AGO), {
    action: "rail",
    px: 100,
  });
});

test("passes to the page at the end when scrolling forward", () => {
  const end = { ...MID, scrollLeft: 599 };
  assert.deepEqual(decide(wheel({ deltaY: 100 }), end, NOW, LONG_AGO), { action: "page" });
  assert.deepEqual(decide(wheel({ deltaY: -100 }), end, NOW, LONG_AGO), {
    action: "rail",
    px: -100,
  });
});

test("converts line and page delta modes to pixels", () => {
  assert.deepEqual(decide(wheel({ deltaY: 3, deltaMode: 1 }), MID, NOW, LONG_AGO), {
    action: "rail",
    px: 3 * LINE_PX,
  });
  assert.deepEqual(decide(wheel({ deltaY: 1, deltaMode: 2 }), MID, NOW, LONG_AGO), {
    action: "rail",
    px: 400,
  });
});
