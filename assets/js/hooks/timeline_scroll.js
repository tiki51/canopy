// Keeps a feed (the channel's, or the thread panel's) pinned to the bottom
// while the reader is already there, and leaves it alone once they scroll up
// to read history. The element to watch is named by data-feed.
//
// A link to one reply (`&reply=`) marks it with data-scroll-target: the feed
// opens on that reply instead of the bottom. data-scope names what the feed
// shows (a thread's root); a new scope resets the pin and the reveal.
//
// The channel feed (data-highlights) also answers the server: a link to one
// message (`?msg=`, from search) pushes "timeline:highlight" with the row's
// id, which is scrolled to the centre and flashed, and the pin let go so the
// feed stays there; "timeline:bottom" (Jump to latest) pins it again.
//
// Two details matter. Programmatic scrolling is instant: a smooth scroll
// fires intermediate scroll events that look like the reader leaving the
// bottom. And growth is watched with a ResizeObserver on the feed, so new
// items, expanding cards, and late-rendering content all keep the pin.
const THRESHOLD = 48

const TimelineScroll = {
  mounted() {
    this.scope = this.el.dataset.scope
    this.stick = true
    this.pinning = false

    this.el.addEventListener("scroll", () => {
      if (this.pinning) return
      this.stick = this.distanceFromBottom() < THRESHOLD
    })

    const feed = (this.el.dataset.feed && this.el.querySelector(this.el.dataset.feed)) || this.el
    this.observer = new ResizeObserver(() => {
      if (this.stick) this.scrollToBottom()
    })
    this.observer.observe(feed)

    if (this.el.dataset.highlights !== undefined) {
      this.handleEvent("timeline:highlight", ({id}) => this.highlight(id, 0))
      this.handleEvent("timeline:bottom", () => {
        this.stick = true
        this.scrollToBottom()
      })
    }

    if (!this.revealTarget()) this.scrollToBottom()
  },

  // The row may render a frame after the event arrives; a few tries cover it.
  highlight(id, tries) {
    const row = document.getElementById(id)
    if (!row || !this.el.contains(row)) {
      if (tries < 10) requestAnimationFrame(() => this.highlight(id, tries + 1))
      return
    }
    this.stick = false
    row.scrollIntoView({block: "center", behavior: "instant"})
    row.classList.remove("search-hit")
    // restart the animation when the same row is pointed at again
    void row.offsetWidth
    row.classList.add("search-hit")
  },

  // A new data-scope (the thread panel showing another thread) starts over:
  // pinned to the bottom, nothing revealed yet.
  updated() {
    if (this.el.dataset.scope !== this.scope) {
      this.scope = this.el.dataset.scope
      this.stick = true
      this.revealed = null
      if (!this.revealTarget()) this.scrollToBottom()
      return
    }
    if (this.revealTarget()) return
    if (this.stick) this.scrollToBottom()
  },

  // Scrolls a newly marked reply into view, once per reply.
  revealTarget() {
    const target = this.el.querySelector("[data-scroll-target]")
    if (!target || target.id === this.revealed) return false
    this.revealed = target.id
    this.stick = false
    target.scrollIntoView({block: "center", behavior: "instant"})
    return true
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
  },

  distanceFromBottom() {
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
  },

  scrollToBottom() {
    this.pinning = true
    this.el.scrollTo({top: this.el.scrollHeight, behavior: "instant"})
    requestAnimationFrame(() => {
      this.el.scrollTo({top: this.el.scrollHeight, behavior: "instant"})
      this.pinning = false
    })
  },
}

export default TimelineScroll
