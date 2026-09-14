// Keeps a <details> open across LiveView patches.
//
// The browser reflects the user's toggle onto the `open` content attribute, but
// the server renders the element without it. When the card re-renders — the live
// telemetry card re-renders on every tool call — morphdom sees an attribute the
// new markup does not have and removes it, snapping the disclosure shut while
// the agent is still working. Capture the state before the patch and restore it
// after, so only the contents update.
const KeepOpen = {
  mounted() {
    this.open = this.el.open
    this.el.addEventListener("toggle", () => { this.open = this.el.open })
  },
  beforeUpdate() {
    this.open = this.el.open
  },
  updated() {
    if (this.el.open !== this.open) this.el.open = this.open
  },
}

export default KeepOpen
