import { Controller } from "../vendor/stimulus.js"
import { ariaSort, next, order, pick, reversed } from "../sort.js"

// Sorts a table by the header clicked, the other way on a second click, or (on a phone, where the
// headers are hidden) by the caption's select and direction button: one choice for both. The choice is kept per
// table (data-sort-key-value) in localStorage and applied whenever the table connects: the event
// stream replaces a whole panel, so each re-render (and each page) arrives here fresh, in the
// server's order. Nothing chosen, that order stands. No timers: a click, or a connect.
//
// Headers: <th data-sort-column="Version" data-sort-type="version"><button data-action="sort#by">.
// Cells: data-sort-value when the text shown is not what to sort by, else their text.
export default class extends Controller {
  static values = { key: String }
  static targets = ["select", "direction"]

  connect() {
    this.rows = Array.from(this.element.tBodies[0]?.rows ?? [])
    this.choice = this.load()
    this.apply()
  }

  by(event) {
    this.choice = next(this.choice, event.currentTarget.closest("th").dataset.sortColumn)
    this.save()
    this.apply()
  }

  choose(event) {
    this.choice = pick(event.currentTarget.value)
    this.save()
    this.apply()
  }

  reverse() {
    this.choice = reversed(this.choice)
    this.save()
    this.apply()
  }

  apply() {
    const headers = Array.from(this.element.tHead?.rows[0]?.cells ?? [])
    let column = -1
    headers.forEach((th, index) => {
      const sort = th.dataset.sortColumn === undefined ? null : ariaSort(this.choice, th.dataset.sortColumn)
      if (sort) column = index
      sort ? th.setAttribute("aria-sort", sort) : th.removeAttribute("aria-sort")
    })
    this.showControl(column < 0 ? null : this.choice)
    const tbody = this.element.tBodies[0]
    if (!tbody) return

    const sorted = column < 0
      ? this.rows
      : order(this.rows.map((row) => value(row.cells[column])), headers[column].dataset.sortType,
        this.choice.direction).map((index) => this.rows[index])
    // Moving rows is a mutation the filter controller hears; make none when nothing moves.
    if (sorted.some((row, index) => tbody.rows[index] !== row)) tbody.append(...sorted)
  }

  // The phone control shows the choice the headers do (none for a column no longer in the table).
  showControl(choice) {
    if (this.hasSelectTarget) this.selectTarget.value = choice?.column ?? ""
    if (!this.hasDirectionTarget) return
    const button = this.directionTarget
    button.disabled = !choice
    button.textContent = choice?.direction === "descending" ? "▼" : "▲"
    button.setAttribute("aria-label", choice ? `Order: ${choice.direction}, reverse` : "Order")
  }

  get storageKey() { return `anfs-ui:sort:${this.keyValue}` }

  load() {
    try {
      const choice = JSON.parse(localStorage.getItem(this.storageKey))
      return choice?.column ? choice : null
    } catch {
      return null
    }
  }

  save() {
    try {
      this.choice
        ? localStorage.setItem(this.storageKey, JSON.stringify(this.choice))
        : localStorage.removeItem(this.storageKey)
    } catch {
      // Storage refused (private window): the choice lasts until the next re-render.
    }
  }
}

function value(cell) {
  if (!cell) return ""
  return cell.dataset.sortValue ?? cell.textContent.trim()
}
