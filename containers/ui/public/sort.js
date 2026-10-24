// How a column's values compare, apart from the page: the sort controller's arithmetic, and what
// spec/js/sort_test.mjs tests under node.

// What a cell shows when there is nothing (Panel's –, the matrix's ·): always after the rest.
const BLANKS = new Set(["", "-", "–", "—", "·"])
const text = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" })

const NUMBER = /^-?\d+(\.\d+)?$/
const VERSION = /^v?\d+(\.\d+)+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$/
const TIME = /^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?$/

export const isBlank = (value) => BLANKS.has(String(value ?? "").trim())

// A column's type from its values, when the header does not name one: whole numbers before
// versions (1.10 is a version, after 1.9), then ISO times, else text.
export function detect(values) {
  const present = values.map((v) => String(v).trim()).filter((v) => !isBlank(v))
  if (present.length === 0) return "text"
  if (present.every((v) => /^-?\d+$/.test(v))) return "number"
  if (present.every((v) => VERSION.test(v))) return "version"
  if (present.every((v) => TIME.test(v))) return "time"
  return "text"
}

// 1.2.10 > 1.2.9; a pre-release before its release (1.0.0-rc1 < 1.0.0); build metadata ignored.
// A value that is not a version goes after those that are.
function version(a, b) {
  const pa = VERSION.test(a)
  const pb = VERSION.test(b)
  if (!pa || !pb) return pa === pb ? text.compare(a, b) : pa ? -1 : 1
  const [mainA, preA] = a.replace(/^v/, "").split("+")[0].split(/-(.*)/s)
  const [mainB, preB] = b.replace(/^v/, "").split("+")[0].split(/-(.*)/s)
  const na = mainA.split(".").map(Number)
  const nb = mainB.split(".").map(Number)
  for (let i = 0; i < Math.max(na.length, nb.length); i++) {
    const d = (na[i] ?? 0) - (nb[i] ?? 0)
    if (d) return d
  }
  if (preA === preB) return 0
  if (preA === undefined) return 1
  if (preB === undefined) return -1
  return text.compare(preA, preB)
}

// The parsed form of a number or a time: NaN goes after the rest, compared as text.
function numeric(parse) {
  return (a, b) => {
    const x = parse(a)
    const y = parse(b)
    if (Number.isNaN(x) || Number.isNaN(y)) {
      return Number.isNaN(x) === Number.isNaN(y) ? text.compare(a, b) : Number.isNaN(x) ? 1 : -1
    }
    return x - y
  }
}

const COMPARE = {
  number: numeric(Number),
  time: numeric(Date.parse),
  version,
  text: (a, b) => text.compare(a, b)
}

export function compare(a, b, type = "text") {
  return (COMPARE[type] ?? COMPARE.text)(String(a).trim(), String(b).trim())
}

// The order of values as indexes: ascending or descending by type, blanks last either way, ties
// in the order given (the server's).
export function order(values, type, direction = "ascending") {
  const kind = type || detect(values)
  const sign = direction === "descending" ? -1 : 1
  return values
    .map((value, index) => ({ value, index, blank: isBlank(value) }))
    .sort((x, y) => {
      if (x.blank !== y.blank) return x.blank ? 1 : -1
      return (x.blank ? 0 : sign * compare(x.value, y.value, kind)) || x.index - y.index
    })
    .map((entry) => entry.index)
}

// The next choice for a click on column: ascending, or the other way when it is already the one.
export function next(choice, column) {
  const direction = choice?.column === column && choice.direction === "ascending" ? "descending" : "ascending"
  return { column, direction }
}

// The phone control's choices: a column picked from the select sorts ascending ("" is none, the
// server's order); the direction button turns the choice the other way.
export const pick = (column) => (column ? { column, direction: "ascending" } : null)
export const reversed = (choice) =>
  choice && { ...choice, direction: choice.direction === "ascending" ? "descending" : "ascending" }

// A header's aria-sort under choice: its direction for the chosen column, nothing for the others.
export const ariaSort = (choice, column) => (choice && choice.column === column ? choice.direction : null)
