// Fits the channel header's one row to the header's own width, so nothing is
// ever clipped: by a narrow window, the side panel (Details narrows it), or a
// long lock or playbook chip. It sets data-fit on the header to the first
// level, least collapsed first, at which the row fits; the "Channel header"
// rules in app.css act on the tokens. The topic goes first, then labels
// shorten, then the spend and Changes buttons go (Details has both), and Stop
// drops its label. From then on the channel name may truncate to NAME_MIN;
// on a phone, or beside Details on a small laptop, the lock chips keep only
// their icon and the agents button only its waiting count (it goes when
// nobody waits: Details has the agents). Past the last level, the name
// truncates further.
const STEPS = [
  "topic",        // the topic hides
  "rest-icons",   // Changes and Details drop their labels
  "agents-short", // "4 agents" hides; "1 waiting on you" becomes "1 waiting"
  "chip-detail",  // lock chips drop "@frontend · 3m"; the playbook chip shows its icon only
  "spend",        // the $ button hides
  "changes",      // Changes hides
  "stop-icon",    // Stop drops its label; the name may truncate from here
  "chip-label",   // lock chips show their icon only; the divider goes
  "agents-count", // the agents button keeps only "1 waiting", or goes
]
const LEVELS = STEPS.map((_, i) => STEPS.slice(0, i).join(" ")).concat([STEPS.join(" ")])

// A topic keeps this much room (or its own width, if less) before it hides;
// the name keeps NAME_MIN once it may truncate.
const TOPIC_MIN = 96
const NAME_MIN = 64

const HeaderFit = {
  mounted() {
    // data-fit belongs to this hook from now on, not to the server's patches.
    this.js().ignoreAttributes(this.el, ["data-fit"])
    this.row = this.el.querySelector("#channel-header-row")
    this.actions = this.el.querySelector("#channel-header-actions")

    this.observer = new ResizeObserver(() => this.fit())
    this.observer.observe(this.row)
    this.observer.observe(this.actions)
    this.fit()
  },

  updated() {
    this.fit()
  },

  destroyed() {
    this.observer.disconnect()
  },

  fit() {
    if (!this.row.isConnected) return
    let level = LEVELS[LEVELS.length - 1]
    for (const candidate of LEVELS) {
      this.el.dataset.fit = candidate
      if (this.fits(candidate.includes("stop-icon"))) { level = candidate; break }
    }
    this.el.dataset.fit = level
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
}

export default HeaderFit
