// Keeps a feed (the channel's, or the thread panel's) pinned to the bottom
// while the reader is already there, and leaves it alone once they scroll up
// to read history. The element to watch is named by data-feed.
//
// A link to one reply (`&reply=`) marks it with data-scroll-target: the feed
// opens on that reply instead of the bottom. data-scope names what the feed
// shows (a thread's root); a new scope resets the pin and the reveal.
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

    if (!this.revealTarget()) this.scrollToBottom()
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
