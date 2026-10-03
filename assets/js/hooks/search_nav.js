// The Search page's keyboard: from the search input, ↑/↓ move through the
// results (the rows in data-results), Enter opens the selected one (the
// search itself when none is), and Esc clears the query.
//
// The selection is aria-selected on a row; the rows are a LiveView stream
// this hook doesn't own, so they are looked up on every key and a selection
// whose row went away (a new search) starts over.
const SearchNav = {
  mounted() {
    this.selected = null

    this.el.addEventListener("keydown", e => {
      if (e.isComposing) return
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        const rows = this.rows()
        if (rows.length === 0) return
        e.preventDefault()
        const at = rows.indexOf(this.selected)
        const next = e.key === "ArrowDown" ? Math.min(at + 1, rows.length - 1) : at - 1
        this.select(next >= 0 ? rows[next] : null)
      } else if (e.key === "Enter" && this.selected && this.selected.isConnected) {
        e.preventDefault()
        this.selected.click()
      } else if (e.key === "Escape" && this.el.value !== "") {
        e.preventDefault()
        this.el.value = ""
        this.select(null)
        this.pushEvent("clear", {})
      }
    })

    // typing starts a new search: nothing is selected in it yet
    this.el.addEventListener("input", () => this.select(null))
  },

  rows() {
    const list = document.querySelector(this.el.dataset.results)
    return list ? Array.from(list.querySelectorAll("[role=option]")) : []
  },

  select(row) {
    if (this.selected && this.selected.isConnected) this.selected.setAttribute("aria-selected", "false")
    this.selected = row
    if (!row) return
    row.setAttribute("aria-selected", "true")
    row.scrollIntoView({block: "nearest"})
  },
}

export default SearchNav
