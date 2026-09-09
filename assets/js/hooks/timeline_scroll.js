// Keeps the channel feed pinned to the bottom while the reader is already
// there, and leaves it alone once they scroll up to read history.
const THRESHOLD = 48

const TimelineScroll = {
  mounted() {
    this.stick = true
    this.el.addEventListener("scroll", () => {
      const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.stick = distance < THRESHOLD
    })
    this.scrollToBottom()
  },

  updated() {
    if (this.stick) this.scrollToBottom()
  },

  scrollToBottom() {
    requestAnimationFrame(() => {
      this.el.scrollTop = this.el.scrollHeight
    })
  },
}

export default TimelineScroll
