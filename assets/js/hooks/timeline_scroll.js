// Keeps the channel feed pinned to the bottom while the reader is already
// there, and leaves it alone once they scroll up to read history.
//
// Two details matter. Programmatic scrolling is instant: a smooth scroll
// fires intermediate scroll events that look like the reader leaving the
// bottom. And growth is watched with a ResizeObserver on the feed, so new
// items, expanding cards, and late-rendering content all keep the pin.
const THRESHOLD = 48

const TimelineScroll = {
  mounted() {
    this.stick = true
    this.pinning = false

    this.el.addEventListener("scroll", () => {
      if (this.pinning) return
      this.stick = this.distanceFromBottom() < THRESHOLD
    })

    const feed = this.el.querySelector("#timeline") || this.el
    this.observer = new ResizeObserver(() => {
      if (this.stick) this.scrollToBottom()
    })
    this.observer.observe(feed)

    this.scrollToBottom()
  },

  updated() {
    if (this.stick) this.scrollToBottom()
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
