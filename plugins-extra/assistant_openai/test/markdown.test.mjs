import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"

// markdown.js is a classic script inlined into the page; evaluate it the same way.
const src = readFileSync(new URL("../src/markdown.js", import.meta.url), "utf8")
const Markdown = new Function(`${src}\nreturn Markdown`)()
const { parse } = Markdown
const t = (text) => ({ t: "text", text })

test("paragraphs split on blank lines and keep single line breaks", () => {
  assert.deepEqual(parse("one\ntwo\n\nthree"), [
    { t: "p", children: [t("one"), { t: "br" }, t("two")] },
    { t: "p", children: [t("three")] },
  ])
})

test("bullet and ordered lists", () => {
  assert.deepEqual(parse("- a\n* b\n\n1. c\n2) d"), [
    { t: "ul", children: [{ t: "li", children: [t("a")] }, { t: "li", children: [t("b")] }] },
    { t: "ol", children: [{ t: "li", children: [t("c")] }, { t: "li", children: [t("d")] }] },
  ])
})

test("headings keep their level", () => {
  assert.deepEqual(parse("## Picks"), [{ t: "h", level: 2, children: [t("Picks")] }])
})

test("fenced code is literal", () => {
  assert.deepEqual(parse("```js\n<b>**x**</b>\n```\nafter"), [
    { t: "pre", text: "<b>**x**</b>" },
    { t: "p", children: [t("after")] },
  ])
})

test("inline code, strong and emphasis", () => {
  assert.deepEqual(parse("a `x` **b** *c* _d_"), [
    {
      t: "p",
      children: [
        t("a "),
        { t: "code", text: "x" },
        t(" "),
        { t: "strong", children: [t("b")] },
        t(" "),
        { t: "em", children: [t("c")] },
        t(" "),
        { t: "em", children: [t("d")] },
      ],
    },
  ])
})

test("links keep only their label", () => {
  assert.deepEqual(parse("see [the docs](https://example.test/x)"), [
    { t: "p", children: [t("see "), t("the docs")] },
  ])
})

test("markup stays text", () => {
  assert.deepEqual(parse("<script>alert(1)</script>"), [
    { t: "p", children: [t("<script>alert(1)</script>")] },
  ])
})

test("arithmetic and snake_case are not emphasis", () => {
  assert.deepEqual(parse("2 * 3 * 4 and snake_case_name"), [
    { t: "p", children: [t("2 * 3 * 4 and snake_case_name")] },
  ])
})

test("empty input", () => {
  assert.deepEqual(parse(""), [])
  assert.deepEqual(parse(null), [])
  assert.deepEqual(parse(undefined), [])
})
