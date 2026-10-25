import assert from "node:assert/strict";
import test from "node:test";

import { createScrub, firstBelow, isCurrentLetter, letterAt } from "../../js/hooks/alpha_jump_bar.mjs";

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

function makeScrub() {
  const shown = [];
  const went = [];
  return { shown, went, scrub: createScrub((l) => shown.push(l), (l) => went.push(l)) };
}

test("a scrub highlights each letter it crosses and navigates once, on release", () => {
  const { shown, went, scrub } = makeScrub();
  scrub.down("a");
  assert.equal(scrub.move("a"), false);
  assert.equal(scrub.move("c"), true);
  assert.equal(scrub.move("c"), false);
  assert.equal(scrub.move("d"), true);
  assert.deepEqual(went, []);
  scrub.up();
  assert.deepEqual(shown, ["c", "d"]);
  assert.deepEqual(went, ["d"]);
});

test("a tap is left to the link, and a drag back to the start still navigates", () => {
  const tap = makeScrub();
  tap.scrub.down("m");
  tap.scrub.up();
  assert.deepEqual(tap.went, []);

  const back = makeScrub();
  back.scrub.down("m");
  back.scrub.move("n");
  back.scrub.move("m");
  back.scrub.up();
  assert.deepEqual(back.went, ["m"]);
});

test("a cancelled scrub, or moves without a press, navigate nowhere", () => {
  const { shown, went, scrub } = makeScrub();
  assert.equal(scrub.move("c"), false);
  scrub.down("a");
  scrub.move("c");
  scrub.cancel();
  scrub.up();
  assert.deepEqual(shown, ["c"]);
  assert.deepEqual(went, []);
});

test("isCurrentLetter matches the URL's letter, whatever its case or encoding", () => {
  assert.equal(isCurrentLetter("m", "?letter=m"), true);
  assert.equal(isCurrentLetter("m", "?sort=title_desc&letter=M&shown=100"), true);
  assert.equal(isCurrentLetter("#", "?letter=%23"), true);
  assert.equal(isCurrentLetter("#", "?letter=m"), false);
  assert.equal(isCurrentLetter("a", "?letter=m"), false);
  assert.equal(isCurrentLetter("m", ""), false);
  assert.equal(isCurrentLetter("m", "?q=m"), false);
  assert.equal(isCurrentLetter(null, "?letter=m"), false);
});
