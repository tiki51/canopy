// The side panel beside the channel feed (a thread, for now). Esc closes it,
// unless a text box in it holds a draft or something inside already handled
// the key (the composer's autocomplete). A key handler on the panel, not on
// the window, so Esc elsewhere on the page keeps its own meaning.
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
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown)
  },
}

export default SidePanel
