// The shell's #canopy-notifier element (CanopyWeb.Layouts.app/1): tells the
// tab's notifier (../notify.js) where the user is and how much waits on them,
// and hands it the "canopy:notify" notes CanopyWeb.Nav pushes, and the
// "canopy:pending" cards a page hears of when it (re)connects. It remounts on
// every live navigation; the notifier keeps everything that must outlast it.
import notifier from "../notify"

const Notifier = {
  mounted() {
    notifier.attach(this)
    this.sync()
    this.handleEvent("canopy:notify", note => notifier.offer(note))
    this.handleEvent("canopy:pending", ({notes}) => notifier.catchUp(notes))
  },

  updated() {
    this.sync()
  },

  destroyed() {
    notifier.detach(this)
  },

  sync() {
    const data = this.el.dataset
    notifier.setPlace({
      channelId: data.channelId || null,
      attention: Number(data.attention || 0),
      attentionChannel: data.attentionChannel || null,
    })
  },
}

export default Notifier
