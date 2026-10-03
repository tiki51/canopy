// Desktop notifications, the browser's half (CanopyWeb.Notify is the
// server's). Every open tab gets the same "canopy:notify" notes from its
// LiveView; this module, one per tab, decides whether one of them shows it.
// It lives outside any hook: hooks remount on every live navigation, and the
// leader lock, the BroadcastChannel and the counters belong to the tab.
//
//   * Preferences are this browser's (localStorage "canopy:notify"): a master
//     switch, off until the user turns it on, one toggle per kind, and sound.
//     Other tabs follow a change through the storage event.
//   * Permission is asked for only from a click: the switch in Settings, or
//     the command palette. Never on load.
//   * A tab where the user is looking (visible and focused; for cards and
//     mentions, on that channel too) vetoes the note for every tab.
//   * One tab, the leader (a Web Lock; a localStorage heartbeat where locks
//     are missing), shows what nobody vetoed after a short wait, at most
//     four a minute; the rest collapse into one "more updates" note.
//   * A page that (re)connects catches up on cards no tab showed or saw.
//   * The title reads "(n) Canopy" while n things wait on the user, and
//     <html data-notify> says whether notifications are on.
//
// Nothing here moves keyboard focus inside the page: an open command palette
// or modal keeps it.

const PREFS_KEY = "canopy:notify"
const SHOWN_KEY = "canopy:notified"
const LEADER_KEY = "canopy:notify-leader"
const SEEN_KEY = "canopy:notify-seen"
const CHANNEL = "canopy:notify"
const DEFAULTS = {enabled: false, needs_you: true, mention: true, work: true, sound: false}
const KINDS = ["needs_you", "mention", "work"]

// longer than the skew between tabs' copies of one push on one machine
const LEADER_WAIT_MS = 300
const RATE_WINDOW_MS = 60_000
const RATE_MAX = 4
// a burst past the limit becomes one note once it settles
const OVERFLOW_SETTLE_MS = 1_000
// a note shown this recently is not shown again (a leader handover mid-burst)
const REMEMBER_MS = 10 * 60_000
// how long shown notes are remembered at all; longer than the server's
// half-hour catch-up window, so a card is never caught up twice
const PRUNE_MS = 60 * 60_000
// a replacement for a tag shown this recently does not sound again
const QUIET_REPLACE_MS = 30_000
const HEARTBEAT_MS = 5_000
const HEARTBEAT_STALE_MS = 15_000

const readJSON = (key, fallback) => {
  try {
    const value = JSON.parse(localStorage.getItem(key) || "null")
    return value && typeof value === "object" ? value : fallback
  } catch (_e) {
    return fallback
  }
}

const writeJSON = (key, value) => {
  try {
    localStorage.setItem(key, JSON.stringify(value))
  } catch (_e) {
    // private mode or a full store: this tab simply forgets
  }
}

class Notifier {
  constructor() {
    this.tabId = Math.random().toString(36).slice(2) + Date.now().toString(36)
    this.channelId = null
    this.attention = 0
    this.attentionChannel = null
    this.hook = null
    this.leader = false
    this.listeners = new Set()
    this.seen = new Map() // note id -> when another tab saw it
    this.shownAt = [] // when the last notes were shown, for the rate limit
    this.tagShownAt = new Map() // tag -> when it was last shown
    this.live = new Map() // tag -> the Notification still on screen
    this.mentions = new Map() // channel id -> mentions since it was looked at
    this.overflow = {count: 0, timer: null, url: null}

    this.channel = "BroadcastChannel" in window ? new BroadcastChannel(CHANNEL) : null
    if (this.channel) this.channel.onmessage = e => this.receive(e.data)

    window.addEventListener("storage", e => {
      if (e.key === PREFS_KEY) {
        if (!this.prefs().enabled) this.closeAll()
        this.emit()
      } else if (e.key === SEEN_KEY && !this.channel) {
        this.receive(readJSON(SEEN_KEY, null))
      }
    })

    const look = () => this.lookedAt()
    document.addEventListener("visibilitychange", look)
    window.addEventListener("focus", look)

    this.watchPermission()
    this.watchTitle()
    this.elect()
    this.emit()
  }

  // -- State -------------------------------------------------------------------

  supported() {
    return "Notification" in window && window.isSecureContext
  }

  permission() {
    return this.supported() ? Notification.permission : "unsupported"
  }

  prefs() {
    return {...DEFAULTS, ...readJSON(PREFS_KEY, {})}
  }

  setPrefs(patch) {
    writeJSON(PREFS_KEY, {...this.prefs(), ...patch})
    this.emit()
  }

  // "unsupported", "blocked" (the browser said no), "on" or "off"
  status() {
    const permission = this.permission()
    if (permission === "unsupported") return "unsupported"
    if (permission === "denied") return "blocked"
    return this.prefs().enabled && permission === "granted" ? "on" : "off"
  }

  // The master switch. Turning it on asks for permission the first time; call
  // it straight from a click, before any await, or the browser refuses to ask.
  // Off closes what is on screen in every tab and keeps the permission.
  setEnabled(on) {
    if (!on) {
      this.setPrefs({enabled: false})
      this.closeAll()
      return Promise.resolve(true)
    }
    if (!this.supported()) return Promise.resolve(false)

    const asked =
      Notification.permission === "default"
        ? Promise.resolve(Notification.requestPermission())
        : Promise.resolve(Notification.permission)

    return asked.then(permission => {
      const granted = permission === "granted"
      if (granted) this.setPrefs({enabled: true})
      else this.emit()
      return granted
    })
  }

  subscribe(fn) {
    this.listeners.add(fn)
    return () => this.listeners.delete(fn)
  }

  // `<html data-notify>` carries the state, for pages that show it from CSS
  // (CanopyWeb.NotifyComponents.current_notify/1).
  emit() {
    document.documentElement.dataset.notify = this.status()
    this.listeners.forEach(fn => {
      try { fn() } catch (_e) { /* a listener's bug is its own */ }
    })
  }

  watchPermission() {
    if (!navigator.permissions || !navigator.permissions.query) return
    navigator.permissions
      .query({name: "notifications"})
      .then(status => { status.onchange = () => this.emit() })
      .catch(() => {})
  }

  // -- Where the user is -------------------------------------------------------

  attach(hook) {
    this.hook = hook
  }

  detach(hook) {
    if (this.hook === hook) this.hook = null
  }

  setPlace({channelId, attention, attentionChannel}) {
    this.channelId = channelId
    this.attentionChannel = attentionChannel
    this.attention = attention
    this.applyTitle()
    this.lookedAt()
  }

  focused() {
    return document.visibilityState === "visible" && document.hasFocus()
  }

  looking(note) {
    if (!this.focused()) return false
    return note.kind === "work" || note.channel_id === this.channelId
  }

  // Back in front of Canopy: the rate limit and the overflow start over, and
  // the open channel's mentions are read; other tabs hear it too.
  lookedAt() {
    if (!this.focused()) return
    this.post({type: "looked", channelId: this.channelId})
    this.receive({type: "looked", channelId: this.channelId})
  }

  // -- Between tabs ------------------------------------------------------------

  post(message) {
    if (this.channel) this.channel.postMessage(message)
    else writeJSON(SEEN_KEY, {...message, at: Date.now(), from: this.tabId})
  }

  receive(message) {
    if (!message || typeof message !== "object") return
    if (message.type === "seen") this.seen.set(message.id, Date.now())
    if (message.type === "looked") {
      this.shownAt = []
      clearTimeout(this.overflow.timer)
      this.overflow = {count: 0, timer: null, url: null}
      if (message.channelId) this.mentions.delete(message.channelId)
    }
  }

  // The first tab to ask holds the lock until it closes; the next in line
  // takes over. Without Web Locks, a heartbeat in localStorage stands in.
  elect() {
    if (navigator.locks && navigator.locks.request) {
      navigator.locks
        .request(LEADER_KEY, () => {
          this.leader = true
          return new Promise(() => {})
        })
        .catch(() => {})
      return
    }

    const beat = () => {
      const now = Date.now()
      const current = readJSON(LEADER_KEY, null)
      if (!current || current.tabId === this.tabId || now - current.at > HEARTBEAT_STALE_MS) {
        writeJSON(LEADER_KEY, {tabId: this.tabId, at: now})
      }
      this.leader = readJSON(LEADER_KEY, {}).tabId === this.tabId
    }
    beat()
    setInterval(beat, HEARTBEAT_MS)
    window.addEventListener("pagehide", () => {
      if (readJSON(LEADER_KEY, {}).tabId === this.tabId) localStorage.removeItem(LEADER_KEY)
    })
  }

  // -- Notes -------------------------------------------------------------------

  wanted(note) {
    const prefs = this.prefs()
    return prefs.enabled && prefs[note.kind] === true && this.permission() === "granted"
  }

  offer(note) {
    if (!note || !KINDS.includes(note.kind)) return
    if (this.looking(note)) {
      // seen here: no tab shows it, now or when catching up later
      this.post({type: "seen", id: note.id})
      this.markShown(note.id)
      if (note.kind === "mention") this.mentions.delete(note.channel_id)
      return
    }
    if (!this.leader || !this.wanted(note)) return
    setTimeout(() => this.decide(note), LEADER_WAIT_MS)
  }

  decide(note) {
    // switched off, seen somewhere, or looked at meanwhile
    if (!this.wanted(note) || this.seen.has(note.id) || this.looking(note)) return
    if (this.shownWithin(note.id, REMEMBER_MS)) return
    this.markShown(note.id)

    if (note.kind === "mention") {
      const count = (this.mentions.get(note.channel_id) || 0) + 1
      this.mentions.set(note.channel_id, count)
      if (count > 1) note = {...note, title: `${count} new mentions in ${note.place}`}
    }

    const now = Date.now()
    this.shownAt = this.shownAt.filter(at => now - at < RATE_WINDOW_MS)
    if (this.shownAt.length >= RATE_MAX) return this.collapse(note)
    this.shownAt.push(now)
    this.show(note)
  }

  // Notes shown (or seen in a tab where the user was looking) are remembered
  // across tabs for an hour, so a new leader, or a page catching up, does not
  // show them again.
  shownWithin(id, ms) {
    const at = readJSON(SHOWN_KEY, {})[id]
    return Boolean(at && Date.now() - at < ms)
  }

  markShown(id) {
    const now = Date.now()
    const kept = {}
    for (const [key, at] of Object.entries(readJSON(SHOWN_KEY, {}))) if (now - at < PRUNE_MS) kept[key] = at
    kept[id] = now
    writeJSON(SHOWN_KEY, kept)
  }

  // After a (re)connect the page hears of the cards still waiting from the
  // last half hour ("canopy:pending"): the ones no tab showed or saw, which
  // arrived while it was asleep or offline. In front of Canopy the badge and
  // the title already say it; elsewhere the leader shows them as one note.
  catchUp(notes) {
    if (!Array.isArray(notes)) return
    const unseen = () => notes.filter(n => n && KINDS.includes(n.kind) && !this.shownWithin(n.id, PRUNE_MS) && !this.seen.has(n.id))
    if (unseen().length === 0) return
    if (this.focused()) {
      unseen().forEach(n => this.markShown(n.id))
      return
    }
    // after the wait: a page just loaded may not have won the lock yet
    setTimeout(() => {
      if (!this.leader) return
      const missed = unseen().filter(n => this.wanted(n))
      if (missed.length === 0 || this.focused()) return
      missed.forEach(n => this.markShown(n.id))
      if (missed.length === 1) return this.show(missed[0])

      const places = [...new Set(missed.map(n => n.place))]
      this.show({
        tag: "canopy:pending",
        title: `${missed.length} things are waiting on you`,
        body: `In ${places.join(", ")}`.slice(0, 140),
        url: missed[0].url,
      })
    }, LEADER_WAIT_MS)
  }

  collapse(note) {
    this.overflow.count += 1
    this.overflow.url = note.url
    clearTimeout(this.overflow.timer)
    this.overflow.timer = setTimeout(() => {
      const count = this.overflow.count
      const url = this.attentionChannel ? `/channels/${this.attentionChannel}` : this.overflow.url
      this.show({
        tag: "canopy:overflow",
        title: `${count} more ${count === 1 ? "update" : "updates"} in Canopy`,
        body: "Open Canopy to catch up.",
        url,
      })
    }, OVERFLOW_SETTLE_MS)
  }

  show(note) {
    const now = Date.now()
    const last = this.tagShownAt.get(note.tag)
    const silent = !this.prefs().sound || Boolean(last && now - last < QUIET_REPLACE_MS)
    this.tagShownAt.set(note.tag, now)

    let shown
    try {
      shown = new Notification(note.title, {body: note.body, tag: note.tag, silent})
    } catch (_e) {
      return
    }
    this.live.set(note.tag, shown)
    shown.onclick = e => {
      if (e && e.preventDefault) e.preventDefault()
      this.click(note, shown)
    }
    shown.onclose = () => {
      if (this.live.get(note.tag) === shown) this.live.delete(note.tag)
    }
  }

  closeAll() {
    this.live.forEach(shown => { try { shown.close() } catch (_e) { /* already gone */ } })
    this.live.clear()
    clearTimeout(this.overflow.timer)
  }

  // Settings → "Send a test notification": past every veto, not past permission.
  test() {
    if (this.permission() !== "granted") return false
    this.show({
      tag: "canopy:test",
      title: "Canopy notifications are on",
      body: "This is how Canopy tells you an agent needs you.",
      url: location.pathname,
    })
    return true
  }

  // -- Click -------------------------------------------------------------------

  click(note, shown) {
    try { window.focus() } catch (_e) { /* not allowed: the OS already raised it */ }
    try { shown.close() } catch (_e) { /* already gone */ }
    if (note.url) this.open(note.url)
  }

  // The leader tab goes there: a patch within the channel, a live navigation
  // elsewhere, then the card or line is scrolled to and flashed. `?msg=`
  // links scroll themselves (the channel view highlights the message).
  open(url) {
    const target = new URL(url, location.origin)
    const anchor = decodeURIComponent(target.hash.slice(1))
    const path = target.pathname + target.search
    const here = location.pathname === target.pathname

    if (here && !target.search) return this.reveal(anchor)
    if (!this.hook) return location.assign(url)

    if (anchor) {
      const landed = () => {
        window.removeEventListener("phx:page-loading-stop", landed)
        // after the feed's own mount scroll, which runs a frame later
        requestAnimationFrame(() => requestAnimationFrame(() => this.reveal(anchor)))
      }
      window.addEventListener("phx:page-loading-stop", landed)
    }
    if (here) this.hook.js().patch(path)
    else this.hook.js().navigate(path)
  }

  reveal(id, tries = 0) {
    if (!id) return
    const el = document.getElementById(id)
    if (!el) {
      if (tries < 30) requestAnimationFrame(() => this.reveal(id, tries + 1))
      return
    }
    el.scrollIntoView({block: "center", behavior: "instant"})
    el.classList.remove("search-hit")
    void el.offsetWidth
    el.classList.add("search-hit")
  }

  // -- Title -------------------------------------------------------------------

  // LiveView rewrites <title> when the page title changes; the prefix goes
  // back on each time.
  watchTitle() {
    const title = document.querySelector("title")
    if (!title) return
    new MutationObserver(() => this.applyTitle()).observe(title, {childList: true, characterData: true, subtree: true})
  }

  applyTitle() {
    const current = document.title
    const base = current.replace(/^\(\d+\) /, "")
    const wanted = this.attention > 0 ? `(${this.attention}) ${base}` : base
    if (current !== wanted) document.title = wanted
  }
}

const notifier = new Notifier()
export default notifier
