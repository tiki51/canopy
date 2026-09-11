// Remembers a per-browser preference. The element declares data-pref (the
// key); on mount a stored value is pushed to the server as "pref", and the
// server pushes "pref" events back to store new values.
const Pref = {
  mounted() {
    const key = "canopy:" + this.el.dataset.pref
    let stored = null
    try { stored = localStorage.getItem(key) } catch (_) {}
    if (stored !== null) this.pushEvent("pref", {key: this.el.dataset.pref, value: stored})
    this.handleEvent("pref", ({key: k, value}) => {
      if (k !== this.el.dataset.pref) return
      try { localStorage.setItem(key, String(value)) } catch (_) {}
    })
  },
}

export default Pref
