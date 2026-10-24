// public/sort.js under node's own runner: node --test spec/js (sort_spec.rb runs it when node is on PATH).
import { test } from "node:test"
import assert from "node:assert/strict"
import { ariaSort, compare, detect, order, next } from "../../public/sort.js"

const sorted = (values, type, direction) => order(values, type, direction).map((i) => values[i])

test("versions by version order, pre-releases before their release", () => {
  assert.deepEqual(sorted(["0.9.0", "0.10.0", "0.2.1", "1.0.0", "1.0.0-rc1"], "version"),
    ["0.2.1", "0.9.0", "0.10.0", "1.0.0-rc1", "1.0.0"])
  assert.deepEqual(sorted(["0.9.0", "0.10.0", "-"], "version", "descending"), ["0.10.0", "0.9.0", "-"])
  assert.ok(compare("v1.2", "1.2.0", "version") === 0)
})

test("numbers numerically", () => {
  assert.deepEqual(sorted(["10", "9", "100", "-1"], "number"), ["-1", "9", "10", "100"])
})

test("times chronologically", () => {
  assert.deepEqual(sorted(["2026-10-23T19:23:00.000Z", "2026-10-23T09:00:00Z", "2025-12-31T23:59:59Z"], "time"),
    ["2025-12-31T23:59:59Z", "2026-10-23T09:00:00Z", "2026-10-23T19:23:00.000Z"])
})

test("text case-insensitively and naturally", () => {
  assert.deepEqual(sorted(["item10", "Item2", "item1", "beta", "Alpha"], "text"),
    ["Alpha", "beta", "item1", "Item2", "item10"])
})

test("blanks last in both directions, ties in the order given", () => {
  for (const direction of ["ascending", "descending"]) {
    assert.deepEqual(sorted(["b", "", "–", "a", "-", "·"], "text", direction).slice(2), ["", "–", "-", "·"])
  }
  assert.deepEqual(order(["x", "X", "x"], "text"), [0, 1, 2])
  assert.deepEqual(order(["x", "X", "x"], "text", "descending"), [0, 1, 2])
})

test("a column's type from its values when not named", () => {
  assert.equal(detect(["3", "12", "–"]), "number")
  assert.equal(detect(["0.1.0", "0.10.2"]), "version")
  assert.equal(detect(["2026-10-23T19:22:07.804Z", ""]), "time")
  assert.equal(detect(["core/ui", "0.1.0"]), "text")
  assert.deepEqual(sorted(["2", "10", "1"]), ["1", "2", "10"])
})

test("a click sorts ascending, again descending, another column ascending; aria-sort follows", () => {
  let choice = next(null, "Version")
  assert.deepEqual(choice, { column: "Version", direction: "ascending" })
  choice = next(choice, "Version")
  assert.equal(choice.direction, "descending")
  assert.equal(next(choice, "Version").direction, "ascending")
  assert.equal(ariaSort(choice, "Version"), "descending")
  assert.equal(ariaSort(choice, "Package"), null)
  assert.equal(ariaSort(null, "Package"), null)
  assert.deepEqual(next(choice, "Package"), { column: "Package", direction: "ascending" })
})
