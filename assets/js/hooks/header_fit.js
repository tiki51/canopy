// Fits the channel header's controls to the header's own width, so none is
// ever clipped: by a narrow window, a side panel, or a long lock or playbook
// chip. It sets data-fit on the header to the first level, least collapsed
// first, at which the row fits; the "Channel header" rules in app.css act on
// the tokens. The order follows what matters most: the plain controls drop
// their labels, then move into the ⋯ menu one by one (least used first), then
// the state chips (locks, playbook, schedules, spend) do the same, and Stop
// drops its label last. Once the state chips collapse, a long channel name
// may truncate too.
//
// It also places the ⋯ menu (a popover, in the top layer) under its button,
// and closes it once an entry is picked.
const STEPS = [
  "rest-icons",
  "m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8",
  "state-icons",
  "s1", "s2", "s3", "s4",
  "stop-icon",
]
const LEVELS = STEPS.map((_, i) => STEPS.slice(0, i).join(" ")).concat([STEPS.join(" ")])

// A topic keeps this much room (or its own width, if less) before controls
// collapse. The channel name is whole until the state chips start to
// collapse; from then on it may truncate down to NAME_MIN, and at the last
// level (everything collapsed) as far as it must.
const TOPIC_MIN = 96
const NAME_MIN = 144

const HeaderFit = {
  mounted() {
    // data-fit belongs to this hook from now on, not to the server's patches.
    this.js().ignoreAttributes(this.el, ["data-fit"])
    this.row = this.el.querySelector("#channel-header-row")
    this.actions = this.el.querySelector("#channel-header-actions")
    this.menu = this.el.querySelector("#channel-more-menu")
    this.button = this.el.querySelector("#channel-more")

    this.observer = new ResizeObserver(() => this.fit())
    this.observer.observe(this.row)
    this.observer.observe(this.actions)
    this.fit()

    this.onToggle = e => { if (e.newState === "open") this.place() }
    this.onPick = e => {
      // Archive's confirmation dialog closes the popover itself.
      if (e.target.closest("[data-hdr-menu]")) this.menu.hidePopover?.()
    }
    this.onResize = () => this.menu.hidePopover?.()
    this.menu.addEventListener("beforetoggle", this.onToggle)
    this.menu.addEventListener("click", this.onPick)
    window.addEventListener("resize", this.onResize)
  },

  updated() {
    this.fit()
  },

  destroyed() {
    this.observer.disconnect()
    window.removeEventListener("resize", this.onResize)
  },

  fit() {
    if (!this.row.isConnected) return
    const before = this.el.dataset.fit
    let level = LEVELS[LEVELS.length - 1]
    for (const candidate of LEVELS) {
      this.el.dataset.fit = candidate
      if (this.fits(candidate.includes("state-icons"))) { level = candidate; break }
    }
    this.el.dataset.fit = level
    // the menu's entries just changed under it: close it rather than let them shift
    if (level !== before && this.menu.matches(":popover-open")) this.menu.hidePopover()
  },

  // Whether the row's contents fit at their natural widths: the menu button,
  // the channel name (whole, or up to NAME_MIN once it may truncate), the
  // topic up to TOPIC_MIN, and the controls.
  fits(nameMayTruncate) {
    const style = getComputedStyle(this.row)
    const gap = parseFloat(style.columnGap) || 0
    const kids = Array.from(this.row.children).filter(kid => kid.getClientRects().length > 0)
    let need = gap * Math.max(0, kids.length - 1)
    for (const kid of kids) {
      if (kid.id === "channel-topic") need += Math.min(kid.scrollWidth, TOPIC_MIN)
      else if (kid.id === "channel-name" && nameMayTruncate) need += Math.min(kid.scrollWidth, NAME_MIN)
      else need += Math.max(kid.scrollWidth, kid.getBoundingClientRect().width)
    }
    // a pixel of slack for sub-pixel widths
    return need + 1 <= this.row.clientWidth
  },

  place() {
    const box = this.button.getBoundingClientRect()
    const root = document.documentElement.style
    root.setProperty("--channel-more-top", `${Math.round(box.bottom + 4)}px`)
    root.setProperty("--channel-more-right", `${Math.max(8, Math.round(window.innerWidth - box.right))}px`)
  },
}

export default HeaderFit
