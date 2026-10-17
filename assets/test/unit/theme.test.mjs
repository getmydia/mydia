import assert from "node:assert/strict";
import test from "node:test";

import {
  MIRROR_KEY,
  applySelection,
  fromPayload,
  resolveThemeId,
} from "../../js/theme.mjs";

function fakeRoot() {
  const attrs = new Map();
  return {
    style: {},
    setAttribute: (k, v) => attrs.set(k, String(v)),
    getAttribute: (k) => (attrs.has(k) ? attrs.get(k) : null),
  };
}

function memoryStorage() {
  const values = new Map();
  return {
    getItem: (k) => (values.has(k) ? values.get(k) : null),
    setItem: (k, v) => values.set(k, v),
  };
}

const selection = {
  mode: "system",
  light: "nord",
  dark: "mocha",
  lightBase: "#eceff4",
  darkBase: "#1e1e2e",
};

test("system mode follows the OS", () => {
  assert.equal(resolveThemeId(selection, true), "mocha");
  assert.equal(resolveThemeId(selection, false), "nord");
});

test("fixed modes ignore the OS", () => {
  assert.equal(resolveThemeId({ ...selection, mode: "light" }, true), "nord");
  assert.equal(resolveThemeId({ ...selection, mode: "dark" }, false), "mocha");
});

test("fromPayload maps the server's keys", () => {
  assert.deepEqual(
    fromPayload({
      mode: "dark",
      light_theme: "nord",
      dark_theme: "mocha",
      light_base: "#eceff4",
      dark_base: "#1e1e2e",
    }),
    { ...selection, mode: "dark" },
  );
});

test("applySelection writes attributes, background and the mirror", () => {
  const root = fakeRoot();
  const storage = memoryStorage();

  applySelection(root, { ...selection, mode: "dark" }, false, storage);

  assert.equal(root.getAttribute("data-theme"), "mocha");
  assert.equal(root.getAttribute("data-theme-mode"), "dark");
  assert.equal(root.getAttribute("data-light-theme"), "nord");
  assert.equal(root.getAttribute("data-dark-theme"), "mocha");
  assert.equal(root.style.backgroundColor, "#1e1e2e");
  assert.deepEqual(JSON.parse(storage.getItem(MIRROR_KEY)), {
    ...selection,
    mode: "dark",
  });
});

test("applySelection survives storage that throws", () => {
  const root = fakeRoot();
  const storage = {
    setItem() {
      throw new Error("quota");
    },
  };

  applySelection(root, selection, true, storage);
  assert.equal(root.getAttribute("data-theme"), "mocha");
});
