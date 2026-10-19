import { Controller } from "../vendor/stimulus.js"

// Hides table rows that do not contain every word typed. The words are
// matched against a row's text plus its data-tokens (source:x status:y).
export default class extends Controller {
  static targets = ["input", "row", "count"]

  connect() {
    this.apply()
  }

  // The event stream replaces the whole table, so rows arrive again unfiltered.
  rowTargetConnected() {
    if (this.pending) return
    this.pending = requestAnimationFrame(() => {
      this.pending = null
      this.apply()
    })
  }

  apply() {
    const words = this.inputTarget.value.toLowerCase().split(/\s+/).filter(Boolean)
    let shown = 0
    for (const row of this.rowTargets) {
      const text = `${row.textContent} ${row.dataset.tokens}`.toLowerCase()
      row.hidden = !words.every((word) => text.includes(word))
      if (!row.hidden) shown++
    }
    this.countTarget.textContent = words.length ? `${shown} of ${this.rowTargets.length}` : `${shown}`
    this.remember()
  }

  // Keep the filter in the address bar so a reload or a shared link keeps it.
  remember() {
    const url = new URL(location.href)
    const query = this.inputTarget.value.trim()
    query ? url.searchParams.set("q", query) : url.searchParams.delete("q")
    history.replaceState(history.state, "", url)
  }
}
