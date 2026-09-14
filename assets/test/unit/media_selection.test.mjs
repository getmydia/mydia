import assert from "node:assert/strict";
import test from "node:test";

import {
  ITEM_SELECTOR,
  MediaSelection,
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

// The hook's own element: mirrors selection mode in data-selecting and names
// the card container, which the hook looks up through `document`.
function syncElement(selecting) {
  return {
    dataset: { container: "media-items", selecting: String(selecting) },
    setSelecting(on) {
      this.dataset.selecting = String(on);
    },
  };
}

function withCards(items, run) {
  const previousDocument = globalThis.document;
  const container = fakeContainer(items);
  globalThis.document = {
    getElementById: (id) => (id === "media-items" ? container : null),
  };

  try {
    run();
  } finally {
    globalThis.document = previousDocument;
  }
}

function mountHook(el) {
  const hook = { el };
  MediaSelection.mounted.call(hook);
  return hook;
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

test("MediaSelection clears every mark when selection mode ends", () => {
  const items = [fakeItem(true), fakeItem(true)];

  withCards(items, () => {
    const el = syncElement(true);
    const hook = mountHook(el);

    el.setSelecting(false);
    MediaSelection.updated.call(hook);
  });

  assert.deepEqual(items.map((item) => item.dataset.selected), ["false", "false"]);
  assert.deepEqual(items.map((item) => item.checkbox.checked), [false, false]);
});

test("MediaSelection keeps a mark added before selection mode has started", () => {
  // The hover checkbox marks its card before the server's patch turns selection
  // mode on. An unrelated patch landing in between must not wipe it.
  const items = [fakeItem(true)];

  withCards(items, () => {
    const hook = mountHook(syncElement(false));
    MediaSelection.updated.call(hook);
  });

  assert.equal(items[0].dataset.selected, "true");
});

test("MediaSelection leaves marks alone while selection mode stays on", () => {
  const items = [fakeItem(true), fakeItem(false)];

  withCards(items, () => {
    const hook = mountHook(syncElement(true));
    MediaSelection.updated.call(hook);
  });

  assert.deepEqual(items.map((item) => item.dataset.selected), ["true", "false"]);
});

test("MediaSelection clears again when a second selection ends", () => {
  const items = [fakeItem(false)];

  withCards(items, () => {
    const el = syncElement(false);
    const hook = mountHook(el);

    el.setSelecting(true);
    MediaSelection.updated.call(hook);
    setItemSelected(items[0], true);

    el.setSelecting(false);
    MediaSelection.updated.call(hook);
    assert.equal(items[0].dataset.selected, "false");

    el.setSelecting(true);
    MediaSelection.updated.call(hook);
    setItemSelected(items[0], true);

    el.setSelecting(false);
    MediaSelection.updated.call(hook);
    assert.equal(items[0].dataset.selected, "false");
  });
});
