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
    removeAttribute: (k) => attrs.delete(k),
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
      radius: "soft",
    }),
    { ...selection, mode: "dark", radius: "soft" },
  );
});

test("applySelection sets data-radius for a preset and mirrors it", () => {
  const root = fakeRoot();
  const storage = memoryStorage();

  applySelection(root, { ...selection, radius: "sharp" }, false, storage);

  assert.equal(root.getAttribute("data-radius"), "sharp");
  assert.equal(JSON.parse(storage.getItem(MIRROR_KEY)).radius, "sharp");
});

test("applySelection removes data-radius for the theme's own corners", () => {
  const root = fakeRoot();
  const storage = memoryStorage();

  applySelection(root, { ...selection, radius: "round" }, false, storage);
  assert.equal(root.getAttribute("data-radius"), "round");

  applySelection(root, { ...selection, radius: "theme" }, false, storage);
  assert.equal(root.getAttribute("data-radius"), null);
});

test("applySelection writes attributes, background and the mirror", () => {
  const root = fakeRoot();
  const storage = memoryStorage();

  applySelection(root, { ...selection, mode: "dark" }, false, storage);

  assert.equal(root.getAttribute("data-theme"), "mocha");
  assert.equal(root.getAttribute("data-theme-mode"), "dark");
  assert.equal(root.getAttribute("data-color-scheme"), "dark");
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

test("applySelection sets data-color-scheme from the resolved slot", () => {
  const root = fakeRoot();
  const storage = memoryStorage();

  applySelection(root, { ...selection, mode: "light" }, true, storage);
  assert.equal(root.getAttribute("data-color-scheme"), "light");

  applySelection(root, { ...selection, mode: "system" }, true, storage);
  assert.equal(root.getAttribute("data-color-scheme"), "dark");
});

function fakeDoc(initial = []) {
  const metas = initial.map((attrs) => fakeMeta(attrs));
  const doc = {
    metas,
    head: { append: (m) => metas.push(m) },
    querySelectorAll: () => [...metas],
    createElement: () => fakeMeta({}),
  };
  function fakeMeta(attrs) {
    const m = {
      attrs: { ...attrs },
      setAttribute: (k, v) => (m.attrs[k] = v),
      remove: () => metas.splice(metas.indexOf(m), 1),
    };
    return m;
  }
  return doc;
}

test("applySelection keeps one theme-color meta for a fixed mode", () => {
  const doc = fakeDoc([
    { name: "theme-color", media: "(prefers-color-scheme: light)", content: "#fff" },
    { name: "theme-color", media: "(prefers-color-scheme: dark)", content: "#000" },
  ]);
  applySelection(fakeRoot(), { ...selection, mode: "dark" }, false, memoryStorage(), doc);
  assert.deepEqual(
    doc.metas.map((m) => m.attrs),
    [{ name: "theme-color", content: "#1e1e2e" }],
  );
  applySelection(fakeRoot(), { ...selection, mode: "light" }, true, memoryStorage(), doc);
  assert.deepEqual(
    doc.metas.map((m) => m.attrs),
    [{ name: "theme-color", content: "#eceff4" }],
  );
});

test("applySelection renders the light/dark media pair for system mode", () => {
  const doc = fakeDoc([{ name: "theme-color", content: "#1e1e2e" }]);
  applySelection(fakeRoot(), selection, false, memoryStorage(), doc);
  assert.deepEqual(
    doc.metas.map((m) => m.attrs),
    [
      { name: "theme-color", media: "(prefers-color-scheme: light)", content: "#eceff4" },
      { name: "theme-color", media: "(prefers-color-scheme: dark)", content: "#1e1e2e" },
    ],
  );
});
