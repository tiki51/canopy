// Flash toasts leave on their own: info after 4s, errors after 8s. Hovering
// pauses the clock so a message can be read; clicking still dismisses at once.
const AutoDismiss = {
  mounted() {
    this.delay = parseInt(this.el.dataset.dismissMs || "4000", 10)
    this.arm()
    this.el.addEventListener("mouseenter", () => this.disarm())
    this.el.addEventListener("mouseleave", () => this.arm())
  },
  updated() { this.arm() },
  destroyed() { this.disarm() },
  arm() {
    this.disarm()
    this.timer = setTimeout(() => this.el.click(), this.delay)
  },
  disarm() {
    if (this.timer) { clearTimeout(this.timer); this.timer = null }
  },
}

export default AutoDismiss
