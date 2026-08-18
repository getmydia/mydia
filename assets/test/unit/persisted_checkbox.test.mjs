import assert from "node:assert/strict";
import test from "node:test";

import {
  applyStoredPreference,
  persistPreference,
} from "../../js/hooks/persisted_checkbox.mjs";

function memoryStorage(initial = {}) {
  const values = new Map(Object.entries(initial));

  return {
    getItem(key) {
      return values.has(key) ? values.get(key) : null;
    },
    setItem(key, value) {
      values.set(key, value);
    },
  };
}

test("defaults auto import to on when no preference has been saved", () => {
  const checkbox = { checked: false };

  applyStoredPreference(checkbox, memoryStorage());

  assert.equal(checkbox.checked, true);
});

test("restores a saved off preference after the checkbox is recreated", () => {
  const storage = memoryStorage({ "mydia:auto-import-confident-matches": "false" });
  const checkbox = { checked: true };

  applyStoredPreference(checkbox, storage);

  assert.equal(checkbox.checked, false);
});

test("persists the checkbox state for the next render", () => {
  const storage = memoryStorage();

  persistPreference({ checked: false }, storage);

  assert.equal(storage.getItem("mydia:auto-import-confident-matches"), "false");
});
