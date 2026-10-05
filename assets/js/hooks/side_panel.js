// The side panel beside the channel feed (a thread, an activity, or the
// channel's details). Esc closes it, unless a text box in it holds a draft or
// something inside already handled the key (the composer's autocomplete). A
// key handler on the panel, not on the window, so Esc elsewhere on the page
// keeps its own meaning.
//
// In Details, "details:focus" (a header chip) scrolls a section into view and
// flashes it.
const SidePanel = {
  mounted() {
    this.onKeydown = e => {
      if (e.key !== "Escape" || e.defaultPrevented) return
      const drafts = this.el.querySelectorAll("textarea, input[type=text], input[type=search]")
      if (Array.from(drafts).some(box => box.value.trim() !== "")) return
      e.preventDefault()
      this.pushEvent("close_panel", {})
    }
    this.el.addEventListener("keydown", this.onKeydown)

    this.handleEvent("details:focus", ({section}) => {
      const target = this.el.querySelector(`[data-section="${CSS.escape(section)}"]`)
      if (!target) return
      target.scrollIntoView({block: "start"})
      target.classList.remove("details-flash")
      void target.offsetWidth
      target.classList.add("details-flash")
      target.addEventListener("animationend", () => target.classList.remove("details-flash"), {once: true})
    })
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
  },
}

export default SidePanel
