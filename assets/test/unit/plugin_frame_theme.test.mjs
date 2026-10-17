import assert from "node:assert/strict"
import test from "node:test"

import { themeMessage } from "../../js/hooks/plugin_frame_theme.mjs"

const root = (scheme, theme = null) => ({
  getAttribute: (name) =>
    name === "data-color-scheme" ? scheme : name === "data-theme" ? theme : null,
})

test("maps the page's scheme to the matching mydia theme", () => {
  assert.deepEqual(themeMessage(root("dark", "mydia-dark")), { mydia: "theme", theme: "mydia-dark" })
  assert.deepEqual(themeMessage(root("light", "mydia-light")), { mydia: "theme", theme: "mydia-light" })
})

test("non-mydia themes are reduced to their scheme", () => {
  assert.deepEqual(themeMessage(root("dark", "dracula")), { mydia: "theme", theme: "mydia-dark" })
  assert.deepEqual(themeMessage(root("light", "nord-light")), { mydia: "theme", theme: "mydia-light" })
})

test("sends nothing for a missing or unknown scheme", () => {
  assert.equal(themeMessage(root(null, "dracula")), null)
  assert.equal(themeMessage(root("sepia")), null)
  assert.equal(themeMessage(root("toString")), null)
  assert.equal(themeMessage(null), null)
})
