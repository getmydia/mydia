import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"

// chats.js is a classic script inlined into the page; evaluate it the same way.
const src = readFileSync(new URL("../src/chats.js", import.meta.url), "utf8")
const Chats = new Function(`${src}\nreturn Chats`)()

const at = (y, m, d, h = 12) => new Date(y, m - 1, d, h).getTime()
const now = at(2026, 9, 30, 15)
const chat = (id, title, updated_at) => ({ id, title, updated_at })

test("ids are uuid-shaped hex and differ", () => {
  const a = Chats.newId()
  assert.match(a, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
  assert.notEqual(a, Chats.newId())
})

test("upsert puts the chat first without duplicating it", () => {
  const list = [chat("a", "A", 1), chat("b", "B", 2)]
  assert.deepEqual(
    Chats.upsert(list, chat("b", "B", 9)).map((c) => [c.id, c.updated_at]),
    [
      ["b", 9],
      ["a", 1],
    ],
  )
  assert.equal(Chats.upsert(list, chat("c", "C", 9)).length, 3)
})

test("groups by local day and drops empty groups", () => {
  const list = [
    chat("a", "Morning", at(2026, 9, 30, 1)),
    chat("b", "Last night", at(2026, 9, 29, 23)),
    chat("c", "Old", at(2026, 9, 20)),
    chat("d", "Adopted", 0),
  ]
  assert.deepEqual(
    Chats.group(list, "", now).map((g) => [g.label, g.chats.map((c) => c.id)]),
    [
      ["Today", ["a"]],
      ["Yesterday", ["b"]],
      ["Earlier", ["c", "d"]],
    ],
  )
  assert.deepEqual(
    Chats.group([list[2]], "", now).map((g) => g.label),
    ["Earlier"],
  )
})

test("filters on the title, ignoring case and outer spaces", () => {
  const list = [chat("a", "Short comedies", now), chat("b", "Downloads", now)]
  assert.deepEqual(
    Chats.group(list, "  COMED ", now)[0].chats.map((c) => c.id),
    ["a"],
  )
  assert.deepEqual(Chats.group(list, "zzz", now), [])
})
