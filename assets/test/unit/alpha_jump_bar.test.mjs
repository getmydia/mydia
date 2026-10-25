import assert from "node:assert/strict";
import test from "node:test";

import { firstBelow, letterAt } from "../../js/hooks/alpha_jump_bar.mjs";

test("firstBelow finds the first card whose bottom is below the edge", () => {
  const bottoms = [10, 20, 30, 40, 50];
  assert.equal(firstBelow(bottoms.length, (i) => bottoms[i], 0), 0);
  assert.equal(firstBelow(bottoms.length, (i) => bottoms[i], 25), 2);
  assert.equal(firstBelow(bottoms.length, (i) => bottoms[i], 30), 3);
  assert.equal(firstBelow(bottoms.length, (i) => bottoms[i], 99), -1);
  assert.equal(firstBelow(0, () => 0, 0), -1);
});

test("letterAt maps a y coordinate onto the strip, clamping at the ends", () => {
  const rects = [
    { letter: "#", top: 0, bottom: 10 },
    { letter: "a", top: 10, bottom: 20 },
    { letter: "b", top: 20, bottom: 30 },
  ];
  assert.equal(letterAt(5, rects), "#");
  assert.equal(letterAt(15, rects), "a");
  assert.equal(letterAt(-40, rects), "#");
  assert.equal(letterAt(400, rects), "b");
  assert.equal(letterAt(5, []), null);
});

test("letterAt picks the nearest entry when the strip spaces its entries out", () => {
  const rects = [
    { letter: "#", top: 0, bottom: 10 },
    { letter: "a", top: 20, bottom: 30 },
    { letter: "b", top: 40, bottom: 50 },
  ];
  assert.equal(letterAt(12, rects), "#");
  assert.equal(letterAt(18, rects), "a");
  assert.equal(letterAt(34, rects), "a");
  assert.equal(letterAt(37, rects), "b");
});
