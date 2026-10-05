// Remembers a per-browser preference. The element declares data-pref (the
// key); on mount a stored value is pushed to the server as "pref", and the
// server pushes "pref" events back to store new values. With
// data-pref-always, an empty value is pushed when nothing is stored, so the
// server knows the browser has nothing (the playbook runs seen). With
// data-pref-media, the push says whether that media query matches
// (`media`), and the stored value is held back when it doesn't: Details
// opens by itself only from lg up. When the query starts or stops matching
// (the window is resized), it is pushed again the same way.
const Pref = {
  mounted() {
    const key = "canopy:" + this.el.dataset.pref
    const query = this.el.dataset.prefMedia
    const push = (value, media) => {
      const payload = {key: this.el.dataset.pref, value}
      if (media !== null) payload.media = media
      this.pushEvent("pref", payload)
    }
    const report = media => {
      let stored = null
      try { stored = localStorage.getItem(key) } catch (_) {}
      if (media === false) stored = null
      if (stored !== null) push(stored, media)
      else if (this.el.dataset.prefAlways || media !== null) push("", media)
    }
    if (query) {
      this.mql = window.matchMedia(query)
      this.onMedia = event => report(event.matches)
      this.mql.addEventListener("change", this.onMedia)
      report(this.mql.matches)
    } else {
      report(null)
    }
    this.handleEvent("pref", ({key: k, value}) => {
      if (k !== this.el.dataset.pref) return
      try { localStorage.setItem(key, String(value)) } catch (_) {}
    })
  },
  destroyed() {
    if (this.mql) this.mql.removeEventListener("change", this.onMedia)
  },
}

export default Pref
