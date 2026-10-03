// "Copy link" on a message or a thread: copies the absolute URL of the path
// in data-href and says so in the button's title for a moment. The title is
// changed through LiveView's JS commands, so a patch while it says "Copied"
// leaves it alone; the original is read once, so a second click cannot keep
// "Copied" for good.
const CopyLink = {
  mounted() {
    this.title = this.el.getAttribute("title")
    this.el.addEventListener("click", () => {
      const url = new URL(this.el.dataset.href, window.location.origin).toString()
      const done = () => {
        this.js().setAttribute(this.el, "title", "Copied")
        this.js().setAttribute(this.el, "data-copied", "true")
        clearTimeout(this.timer)
        this.timer = setTimeout(() => {
          this.js().setAttribute(this.el, "title", this.title)
          this.js().removeAttribute(this.el, "data-copied")
        }, 1500)
      }
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(url).then(done, () => {})
      } else {
        // plain http on a LAN (CANOPY_BIND): the clipboard API is unavailable
        const box = document.createElement("textarea")
        box.value = url
        box.setAttribute("readonly", "")
        box.style.position = "fixed"
        box.style.opacity = "0"
        document.body.appendChild(box)
        box.select()
        try { document.execCommand("copy"); done() } catch (_e) {}
        box.remove()
      }
    })
  },

  destroyed() {
    clearTimeout(this.timer)
  },
}

export default CopyLink
