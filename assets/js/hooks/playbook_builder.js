// The playbook builder's browser side (CanopyWeb.PlaybookBuilderLive):
//
//   * ⌘S / Ctrl+S clicks Save (so its confirm still applies); Enter in a
//     one-line field never submits the form
//   * leaving with unsaved changes asks first: `beforeunload` for the tab,
//     and a confirm on LiveView links and on Back/Forward
//   * the Markdown toolbar wraps the selection in its textarea
//   * steps reorder by dragging the grip (SortableJS) or from the keyboard:
//     Space or Enter on the grip lifts the step, ↑/↓ move it, Space or Enter
//     drops it, Esc puts it back. Either way the server gets `reorder` with
//     the step uids in their new order.
//   * `builder:focus` and `builder:flash` from the server focus a field, or
//     scroll to a step and flash it
import Sortable from "../../vendor/sortable"

const MARKS = {
  bold: ["**", "**", "bold text"],
  italic: ["_", "_", "italic text"],
  code: ["`", "`", "code"],
  mention: ["@", "", "agent"],
}

const PlaybookBuilder = {
  mounted() {
    this.onKey = e => this.key(e)
    this.onUnload = e => {
      if (!this.dirty()) return
      e.preventDefault()
      e.returnValue = ""
    }
    this.onNav = e => this.guardLink(e)
    this.onPop = e => this.guardHistory(e)
    this.here = {url: window.location.href, state: window.history.state}
    this.onMouseDown = e => { if (e.target.closest("[data-md]")) e.preventDefault() }
    this.onClick = e => {
      const button = e.target.closest("[data-md]")
      if (button) this.markdown(button)
    }
    this.onGripKey = e => this.gripKey(e)

    window.addEventListener("keydown", this.onKey)
    window.addEventListener("beforeunload", this.onUnload)
    document.addEventListener("click", this.onNav, true)
    // capture runs before LiveView's own popstate listener, so a cancelled
    // Back never reaches it
    window.addEventListener("popstate", this.onPop, true)
    this.el.addEventListener("mousedown", this.onMouseDown)
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("keydown", this.onGripKey)

    this.handleEvent("builder:focus", ({id}) => {
      requestAnimationFrame(() => {
        const el = document.getElementById(id)
        if (el) { el.focus(); if (el.select && el.value === "") el.select() }
      })
    })
    this.handleEvent("builder:flash", ({id}) => {
      requestAnimationFrame(() => {
        const el = document.getElementById(id)
        if (!el) return
        el.scrollIntoView({behavior: "smooth", block: "center"})
        el.classList.remove("step-flash")
        void el.offsetWidth
        el.classList.add("step-flash")
        el.addEventListener("animationend", () => el.classList.remove("step-flash"), {once: true})
      })
    })

    this.sortable()
  },

  updated() {
    this.here = {url: window.location.href, state: window.history.state}
    this.sortable()
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKey)
    window.removeEventListener("beforeunload", this.onUnload)
    document.removeEventListener("click", this.onNav, true)
    window.removeEventListener("popstate", this.onPop, true)
    if (this.sorter) this.sorter.destroy()
  },

  dirty() { return this.el.dataset.dirty === "true" },

  key(e) {
    if ((e.metaKey || e.ctrlKey) && !e.altKey && (e.key === "s" || e.key === "S")) {
      e.preventDefault()
      const save = document.getElementById("save-playbook")
      if (save && !save.disabled) save.click()
      return
    }
    const t = e.target
    if (e.key === "Enter" && t.tagName === "INPUT" && t.form && t.form.id === "builder-form" &&
        t.type !== "checkbox") {
      e.preventDefault()
    }
  },

  guardLink(e) {
    if (!this.dirty() || e.defaultPrevented) return
    const link = e.target.closest("a[data-phx-link]")
    if (!link || e.metaKey || e.ctrlKey || e.shiftKey) return
    const title = this.el.dataset.title || "this playbook"
    if (!window.confirm(`Discard your changes to ${title}?`)) {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  },

  // Back or Forward has already moved the address; on Cancel, put this page's
  // entry back and keep LiveView from following it
  guardHistory(e) {
    if (!this.dirty() || window.location.href === this.here.url) return
    const title = this.el.dataset.title || "this playbook"
    if (window.confirm(`Discard your changes to ${title}?`)) return
    e.stopImmediatePropagation()
    window.history.pushState(this.here.state, "", this.here.url)
  },

  // -- Markdown toolbar -------------------------------------------------------

  markdown(button) {
    const bar = button.closest("[data-md-toolbar]")
    const area = bar && document.getElementById(bar.dataset.mdToolbar)
    if (!area) return
    const {selectionStart: start, selectionEnd: end, value} = area
    const selected = value.slice(start, end)
    let text, caretStart, caretEnd

    if (button.dataset.md === "list") {
      const lineStart = value.lastIndexOf("\n", start - 1) + 1
      const block = value.slice(lineStart, end) || ""
      const listed = (block || "").split("\n").map(l => l.startsWith("- ") ? l : "- " + l).join("\n")
      area.setRangeText(listed, lineStart, end, "end")
      caretStart = caretEnd = lineStart + listed.length
    } else {
      const [open, close, sample] = MARKS[button.dataset.md]
      const inner = selected || sample
      text = open + inner + close
      area.setRangeText(text, start, end, "end")
      caretStart = start + open.length
      caretEnd = caretStart + inner.length
    }
    area.focus()
    area.setSelectionRange(caretStart, caretEnd)
    area.dispatchEvent(new Event("input", {bubbles: true}))
  },

  // -- Reordering -------------------------------------------------------------

  list() { return this.el.querySelector("[data-sortable]") },
  rows() { return Array.from(this.list().querySelectorAll(":scope > li[data-uid]")) },
  announcer() { return document.getElementById("drag-announcer") },

  sortable() {
    const list = this.list()
    if (!list) {
      if (this.sorter) { this.sorter.destroy(); this.sorter = null }
      return
    }
    if (this.sorter && this.sorter.el === list) return
    if (this.sorter) this.sorter.destroy()
    this.sorter = Sortable.create(list, {
      handle: "[data-grip]",
      draggable: "li[data-uid]",
      animation: 150,
      ghostClass: "step-ghost",
      chosenClass: "step-drag",
      onStart: e => { this.dragging = e.item; this.announce(e.item) },
      onChange: e => { this.renumber(); this.announce(e.item) },
      onEnd: e => {
        this.dragging = null
        this.quiet()
        if (e.oldIndex !== e.newIndex) this.pushEvent("reorder", {uids: this.rows().map(r => r.dataset.uid)})
      },
    })
  },

  renumber() {
    this.rows().forEach((row, i) => {
      const n = row.querySelector("[data-number]")
      if (n) n.textContent = String(i + 1)
    })
  },

  // "Moving Review to step 4 · it still sends back to Fix · Esc cancels"
  // (Esc only for a keyboard move; SortableJS has no cancel for a mouse drag)
  announce(row) {
    const rows = this.rows()
    const at = rows.indexOf(row)
    const title = row.dataset.title
    let loop = ""
    if (row.dataset.onReject) {
      const target = rows.find(r => r.dataset.stepId === row.dataset.onReject)
      const targetTitle = target ? target.dataset.title : row.dataset.onReject
      loop = target && rows.indexOf(target) < at
        ? ` · it still sends back to ${targetTitle}`
        : ` · ${targetTitle} would come after it, so it can't send work back there`
    }
    const pill = this.announcer()
    if (pill) {
      pill.dataset.active = ""
      const cancel = this.lifted ? " · Esc cancels" : ""
      pill.textContent = `Moving ${title} to step ${at + 1}${loop}${cancel}`
    }
    const ghost = this.list().querySelector(".step-ghost")
    if (ghost) ghost.dataset.dropLabel = `Drop to make ${title} step ${at + 1}`
  },

  quiet() {
    const pill = this.announcer()
    if (!pill) return
    delete pill.dataset.active
    pill.textContent = "Drag ⋮⋮ to reorder · click a step to open it"
  },

  gripKey(e) {
    const grip = e.target.closest("[data-grip]")
    if (!grip) return
    const row = grip.closest("li[data-uid]")
    const lifted = this.lifted

    if (!lifted && (e.key === " " || e.key === "Enter")) {
      e.preventDefault()
      this.lifted = {row, order: this.rows().map(r => r.dataset.uid)}
      row.classList.add("step-drag")
      this.announce(row)
      return
    }
    if (!lifted || lifted.row !== row) return

    if (e.key === "ArrowUp" || e.key === "ArrowDown") {
      e.preventDefault()
      const sibling = e.key === "ArrowUp" ? row.previousElementSibling : row.nextElementSibling
      if (sibling && sibling.matches("li[data-uid]")) {
        if (e.key === "ArrowUp") sibling.before(row); else sibling.after(row)
        grip.focus()
        this.renumber()
        this.announce(row)
      }
    } else if (e.key === " " || e.key === "Enter") {
      e.preventDefault()
      this.drop(true)
    } else if (e.key === "Escape") {
      e.preventDefault()
      e.stopPropagation()
      this.drop(false)
    } else if (e.key === "Tab") {
      this.drop(false)
    }
  },

  drop(keep) {
    const {row, order} = this.lifted
    this.lifted = null
    row.classList.remove("step-drag")
    this.quiet()
    const now = this.rows().map(r => r.dataset.uid)
    if (keep) {
      if (now.join() !== order.join()) this.pushEvent("reorder", {uids: now})
    } else {
      const list = this.list()
      order.forEach(uid => { const r = list.querySelector(`:scope > li[data-uid="${uid}"]`); if (r) list.appendChild(r) })
      this.renumber()
    }
    const grip = row.querySelector("[data-grip]")
    if (grip) requestAnimationFrame(() => grip.focus())
  },
}

export default PlaybookBuilder
