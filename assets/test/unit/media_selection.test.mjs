import assert from "node:assert/strict";
import test from "node:test";

import {
  ITEM_SELECTOR,
  setAllSelected,
  setItemSelected,
  toggleAllSelected,
} from "../../js/hooks/media_selection.mjs";

function fakeItem(selected = false, { checkbox = true } = {}) {
  const box = checkbox ? { checked: selected } : null;

  return {
    dataset: { selected: String(selected) },
    checkbox: box,
    querySelector(selector) {
      return selector === "input.select-checkbox" ? box : null;
    },
  };
}

function fakeContainer(items) {
  return {
    querySelectorAll(selector) {
      assert.equal(selector, ITEM_SELECTOR);
      return items;
    },
  };
}

test("setItemSelected marks the card and its hidden checkbox together", () => {
  const item = fakeItem(false);

  setItemSelected(item, true);
  assert.equal(item.dataset.selected, "true");
  assert.equal(item.checkbox.checked, true);

  setItemSelected(item, false);
  assert.equal(item.dataset.selected, "false");
  assert.equal(item.checkbox.checked, false);
});

test("setItemSelected still marks a card that has no checkbox", () => {
  const item = fakeItem(false, { checkbox: false });

  assert.doesNotThrow(() => setItemSelected(item, true));
  assert.equal(item.dataset.selected, "true");
});

test("setAllSelected applies to every media item in the container", () => {
  const items = [fakeItem(false), fakeItem(true), fakeItem(false)];

  setAllSelected(fakeContainer(items), true);
  assert.deepEqual(items.map((item) => item.dataset.selected), ["true", "true", "true"]);

  setAllSelected(fakeContainer(items), false);
  assert.deepEqual(items.map((item) => item.checkbox.checked), [false, false, false]);
});

test("toggleAllSelected selects everything unless everything is already selected", () => {
  const items = [fakeItem(true), fakeItem(false)];

  toggleAllSelected(fakeContainer(items));
  assert.deepEqual(items.map((item) => item.dataset.selected), ["true", "true"]);

  toggleAllSelected(fakeContainer(items));
  assert.deepEqual(items.map((item) => item.dataset.selected), ["false", "false"]);
});
