import assert from "node:assert/strict";
import test from "node:test";

import { focusLeftAlone, keyDirection, orderedKeys, sameOrder } from "../../js/hooks/home_widget_sort.mjs";

test("maps ArrowUp and ArrowDown to move directions", () => {
  assert.equal(keyDirection({ key: "ArrowUp" }), "up");
  assert.equal(keyDirection({ key: "ArrowDown" }), "down");
});

test("ignores other keys and modified arrows", () => {
  assert.equal(keyDirection({ key: "Enter" }), null);
  assert.equal(keyDirection({ key: "ArrowLeft" }), null);
  assert.equal(keyDirection({ key: "ArrowUp", altKey: true }), null);
  assert.equal(keyDirection({ key: "ArrowDown", ctrlKey: true }), null);
  assert.equal(keyDirection({ key: "ArrowDown", metaKey: true }), null);
  assert.equal(keyDirection({ key: "ArrowDown", shiftKey: true }), null);
});

test("reads data-key from rows in DOM order", () => {
  const container = {
    querySelectorAll: (selector) => {
      assert.equal(selector, ":scope > [data-key]");
      return [{ dataset: { key: "episodes" } }, { dataset: { key: "library_stats" } }];
    },
  };
  assert.deepEqual(orderedKeys(container), ["episodes", "library_stats"]);
});

test("sameOrder compares keys by position", () => {
  assert.equal(sameOrder(["a", "b"], ["a", "b"]), true);
  assert.equal(sameOrder(["a", "b"], ["b", "a"]), false);
  assert.equal(sameOrder(["a"], ["a", "b"]), false);
});

test("focusLeftAlone restores focus only when the user has not moved it", () => {
  const body = {};
  const doc = { body };
  body.ownerDocument = doc;
  const handle = { ownerDocument: doc };
  const elsewhere = { ownerDocument: doc };
  assert.equal(focusLeftAlone(null, handle), true);
  assert.equal(focusLeftAlone(body, handle), true);
  assert.equal(focusLeftAlone(handle, handle), true);
  assert.equal(focusLeftAlone(elsewhere, handle), false);
});
