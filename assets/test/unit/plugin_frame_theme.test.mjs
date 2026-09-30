import assert from "node:assert/strict"
import test from "node:test"

import { themeMessage } from "../../js/hooks/plugin_frame_theme.mjs"

const root = (theme) => ({ getAttribute: (name) => (name === "data-theme" ? theme : null) })

test("posts the host's mydia themes", () => {
  assert.deepEqual(themeMessage(root("mydia-dark")), { mydia: "theme", theme: "mydia-dark" })
  assert.deepEqual(themeMessage(root("mydia-light")), { mydia: "theme", theme: "mydia-light" })
})

test("sends nothing for a missing or unknown theme", () => {
  assert.equal(themeMessage(root(null)), null)
  assert.equal(themeMessage(root("dracula")), null)
  assert.equal(themeMessage(null), null)
})
