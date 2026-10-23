// The channel composer, and the thread panel's: Enter sends, Shift+Enter
// inserts a newline, typing `@` opens an autocomplete of agents and teams and
// `#` one of channels. The textarea keeps its text on a failed send; the
// server pushes "composer:clear" on success. Both composers share this hook:
// each finds its popup, highlight layer, hint, and upload through its own data
// attributes, and "composer:focus" / "composer:clear" name the textarea they
// are for ({id}).
//
// When the draft mentions an agent that is blocked on a question or permission
// card (the form's data-awaiting), a hint says the message will not answer the
// card: the text never round-trips, so the hint is drawn here. With interrupts
// on (data-interrupt), a mention of an agent that is working (data-working)
// gets a hint too: it reads the message after its current step.
//
// A live @here in the draft (a `here` token, as the highlighter sees it) puts
// a line under the box (data-here-hint): who it wakes, which of them are
// working, and which members are off (data-here, [{name, working, active}] in
// roster order).
// The autocomplete offers @here first, with the count.
//
// Alt+Enter sends the other way round from the setting (without interrupting
// a working agent): the form's hidden `interrupt` input says "toggle" for
// that one submit.
//
// Mentions, channels and commands in the draft are highlighted by a layer
// behind the textarea (composer_highlight.js).
//
// The command palette writes slash commands into the channel's composer:
// "cmdk:prefill" ({text}) from the same page, or a sessionStorage draft
// ("canopy:cmdk-draft:<channel id>") left by a palette on another page, read
// once when this composer mounts.
//
// Height: one row by default, growing with its content up to AUTO_MAX. The
// browser's resize handle is off (CSS resize-none); the manual-floor tracking
// below is kept in case it is ever turned back on.
import Highlighter, {draftContext} from "../composer_highlight"
import {maskCode, tokenize} from "../composer_tokens"
import {pastedFiles} from "../pasted_files"

const MAX_SUGGESTIONS = 8
const DRAFT_PREFIX = "canopy:cmdk-draft:"
const AUTO_MAX = 192
// The @here hint names this many agents in full; past it, 5 and "and N more".
const HERE_NAMES = 6

// Shows a hint slot with these nodes, or hides it when there are none.
function fill(slot, nodes) {
  if (!slot) return
  slot.replaceChildren(...nodes)
  slot.classList.toggle("hidden", nodes.length === 0)
}

const Composer = {
  mounted() {
    this.index = 0
    this.matches = []
    this.popup = document.querySelector(this.el.dataset.suggestions)

    this.manual = null
    this.lastAuto = null

    const mine = detail => Boolean(detail) && detail.id === this.el.id

    // Opening a thread puts the caret in its composer, so the reply can be
    // typed without a second click.
    this.handleEvent("composer:focus", detail => {
      if (mine(detail)) this.el.focus()
    })

    this.handleEvent("composer:clear", detail => {
      if (!mine(detail)) return
      this.clear()
      this.el.focus()
    })

    // The waiting agents change as cards come and go; LiveView patches the
    // form's attribute, never the textarea, so watch the attribute. The
    // form's data-scope names what the draft belongs to (the thread panel's
    // root): when it changes, the draft is another thread's and is dropped.
    this.hint = this.el.dataset.hint ? document.querySelector(this.el.dataset.hint) : null
    this.hereHint = this.el.dataset.hereHint ? document.querySelector(this.el.dataset.hereHint) : null
    if (this.el.form) {
      this.scope = this.el.form.dataset.scope
      this.formObserver = new MutationObserver(() => {
        if (this.el.form.dataset.scope !== this.scope) {
          this.scope = this.el.form.dataset.scope
          this.clear()
        }
        this.renderHint()
      })
      this.formObserver.observe(this.el.form, {
        attributes: true,
        attributeFilter: ["data-awaiting", "data-working", "data-interrupt", "data-scope", "data-here", "data-dm", "data-thread", "data-agents", "data-commands"],
      })
    }

    const layer = this.el.dataset.highlight && document.querySelector(this.el.dataset.highlight)
    if (layer) this.highlighter = new Highlighter(this.el, layer)

    // A height we did not set ourselves is the reader dragging the handle.
    // The highlight layer follows every size change.
    this.observer = new ResizeObserver(() => {
      const height = this.el.offsetHeight
      if (this.lastAuto !== null && Math.abs(height - this.lastAuto) > 2) this.manual = height
      if (this.highlighter) this.highlighter.sync()
    })
    this.observer.observe(this.el)

    this.el.addEventListener("keydown", e => this.onKeydown(e))
    this.el.addEventListener("input", () => {
      this.autosize()
      this.refresh()
      this.renderHint()
      if (this.highlighter) this.highlighter.schedule()
    })
    this.el.addEventListener("blur", () => setTimeout(() => this.hide(), 150))
    this.el.addEventListener("paste", e => this.onPaste(e))

    if (this.popup) {
      this.popup.addEventListener("mousedown", e => {
        const button = e.target.closest("[data-name]")
        if (button) {
          e.preventDefault()
          this.choose(button.dataset.name)
        }
      })
    }

    this.autosize()

    if (this.el.id === "composer-input") {
      this.el.addEventListener("cmdk:prefill", e => this.prefill(e.detail && e.detail.text))
      const channel = (window.location.pathname.match(/^\/channels\/([^/]+)$/) || [])[1]
      let draft = null
      try {
        if (channel) {
          draft = sessionStorage.getItem(DRAFT_PREFIX + channel)
          sessionStorage.removeItem(DRAFT_PREFIX + channel)
        }
      } catch (_e) {
        draft = null
      }
      if (draft) this.prefill(draft)
    }
  },

  // A command from the palette: it replaces an empty draft or one that is
  // itself a command, and goes in front of anything else typed. The caret
  // lands after it, so "/delegate @" opens the agent list.
  prefill(text) {
    if (!text) return
    const draft = this.el.value.trim()
    const command = draft.match(/^\/(\w+)/)
    const replace = draft === "" || (command && this.list("commands").includes(command[1].toLowerCase()))
    this.el.value = replace ? text : text + (text.endsWith(" ") ? "" : " ") + draft
    this.el.focus()
    this.el.setSelectionRange(text.length, text.length)
    this.autosize()
    this.el.dispatchEvent(new Event("input", {bubbles: true}))
  },

  // Pasted files go straight to the upload config; text pastes are left to
  // the browser.
  onPaste(e) {
    const files = pastedFiles(e)
    if (files.length === 0) return
    e.preventDefault()
    this.upload(this.el.dataset.upload || "files", files)
  },

  // The agent, team, and channel lists live on the form, which LiveView keeps
  // current; the textarea itself is never patched. `@` offers agents first,
  // then teams (data-teams), which share the @ namespace. The keyword `here`
  // is offered on its own (refresh), so a legacy agent or team called `here`
  // is left out.
  candidates(trigger) {
    if (trigger === "#") return this.list("channels")
    if (trigger === "/") return this.list("slash").map(c => c.name)
    return this.list("agents").concat(this.list("teams")).filter(name => name.toLowerCase() !== "here")
  },

  // The channel's agent members for @here (data-here), in roster order.
  here() {
    return this.list("here")
  },

  // Where a draft's @here reaches: "#name", or "this DM".
  herePlace() {
    const form = this.el.form
    if (form && form.dataset.dm === "true") return "this DM"
    return "#" + ((form && form.dataset.channelName) || "")
  },

  list(key) {
    try {
      const source = (this.el.form && this.el.form.dataset[key]) || this.el.dataset[key] || "[]"
      return JSON.parse(source)
    } catch (_e) {
      return []
    }
  },

  onKeydown(e) {
    if (this.matches.length > 0) {
      if (e.key === "ArrowDown") {
        e.preventDefault()
        this.index = (this.index + 1) % this.matches.length
        return this.renderPopup()
      }
      if (e.key === "ArrowUp") {
        e.preventDefault()
        this.index = (this.index - 1 + this.matches.length) % this.matches.length
        return this.renderPopup()
      }
      if (e.key === "Tab" || e.key === "Enter") {
        e.preventDefault()
        return this.choose(this.matches[this.index])
      }
      // handled here, so the side panel does not take it as "close"
      if (e.key === "Escape") {
        e.preventDefault()
        return this.hide()
      }
    }

    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault()
      if (this.el.value.trim() !== "" && this.el.form) this.sendDraft(e.altKey)
    }
  },

  // `toggle`: Alt+Enter, sent the other way round from the setting. The
  // input is reset once the submit has read it, so the next Enter is plain.
  sendDraft(toggle) {
    const input = this.el.form.querySelector("input[name=interrupt]")
    if (input) input.value = toggle ? "toggle" : ""
    this.el.form.requestSubmit()
    if (input) setTimeout(() => { input.value = "" }, 0)
  },

  // The `@word` or `#word` immediately before the caret, if any.
  currentMention() {
    const caret = this.el.selectionStart
    const before = this.el.value.slice(0, caret)
    // `/` opening the draft offers the commands (the palette's catalog)
    const slash = before.match(/^\/(\w*)$/)
    if (slash) return {trigger: "/", start: 0, query: slash[1].toLowerCase(), caret}
    const match = before.match(/(?:^|[^\w@#])([@#])([a-z0-9_-]*)$/i)
    if (!match) return null
    return {trigger: match[1], start: caret - match[2].length - 1, query: match[2].toLowerCase(), caret}
  },

  refresh() {
    const mention = this.currentMention()
    if (!mention) return this.hide()

    this.mention = mention
    this.matches = this.candidates(mention.trigger)
      .filter(name => name.toLowerCase().startsWith(mention.query))
      .slice(0, MAX_SUGGESTIONS)
    // @here goes first while the query could still spell it, when it would
    // wake someone
    if (mention.trigger === "@" && "here".startsWith(mention.query) && this.hereCount() > 0) {
      this.matches = ["here"].concat(this.matches).slice(0, MAX_SUGGESTIONS)
    }
    this.index = Math.min(this.index, Math.max(this.matches.length - 1, 0))

    // a command typed in full has nothing left to complete: Enter sends it
    if (mention.trigger === "/" && this.matches.includes(mention.query)) return this.hide()
    if (this.matches.length === 0) return this.hide()
    this.renderPopup()
  },

  renderPopup() {
    if (!this.popup) return
    this.popup.innerHTML = ""
    this.matches.forEach((name, i) => {
      const button = document.createElement("button")
      button.type = "button"
      button.dataset.name = name
      button.className =
        "flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm " +
        (i === this.index ? "bg-primary text-primary-content" : "hover:bg-base-200")
      const trigger = this.mention ? this.mention.trigger : "@"
      if (trigger === "/") {
        const entry = this.list("slash").find(c => c.name === name)
        const label = document.createElement("span")
        label.textContent = "/" + name
        label.className = "shrink-0 font-mono"
        const summary = document.createElement("span")
        summary.className = "min-w-0 truncate text-xs opacity-70"
        summary.textContent = entry ? entry.summary : ""
        if (entry) button.title = entry.usage
        button.append(label, summary)
      } else if (trigger === "@" && name === "here") {
        this.renderHereRow(button, i === this.index)
      } else {
        button.textContent = trigger + name
      }
      this.popup.appendChild(button)
    })
    this.popup.classList.remove("hidden")
  },

  // The @here row: megaphone, @here, where it reaches, and the count.
  renderHereRow(button, selected) {
    const icon = document.createElement("span")
    icon.className = "hero-megaphone size-4 shrink-0"
    icon.setAttribute("aria-hidden", "true")
    const label = document.createElement("span")
    label.className = "font-medium"
    label.textContent = "@here"
    const place = document.createElement("span")
    place.className = "min-w-0 truncate text-xs opacity-80"
    place.textContent = "everyone in " + this.herePlace()
    const count = document.createElement("span")
    count.className =
      "ml-auto rounded-full px-1.5 text-xs font-medium " + (selected ? "bg-white/20" : "bg-base-300/60")
    count.textContent = String(this.hereCount())
    button.append(icon, label, place, count)
  },

  hereCount() {
    return this.here().filter(agent => agent.active).length
  },

  choose(name) {
    const mention = this.mention || this.currentMention()
    if (!mention) return this.hide()
    const value = this.el.value
    const insert = mention.trigger + name + " "
    this.el.value = value.slice(0, mention.start) + insert + value.slice(mention.caret)
    const caret = mention.start + insert.length
    this.el.setSelectionRange(caret, caret)
    this.hide()
    this.autosize()
    this.el.dispatchEvent(new Event("input", {bubbles: true}))
  },

  // An empty composer: the text, its height, and one-shot choices such as
  // "Also send to channel".
  clear() {
    this.el.value = ""
    this.el.style.height = this.manual ? this.manual + "px" : ""
    if (this.el.form) this.el.form.querySelectorAll("input[data-clear]").forEach(box => { box.checked = false })
    this.hide()
    this.renderHint()
    if (this.highlighter) this.highlighter.render()
  },

  hide() {
    this.matches = []
    this.index = 0
    this.mention = null
    if (this.popup) {
      this.popup.classList.add("hidden")
      this.popup.innerHTML = ""
    }
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
    if (this.formObserver) this.formObserver.disconnect()
    if (this.highlighter) this.highlighter.destroy()
  },

  // Agents named in the draft out of the form's list `key` (data-awaiting:
  // waiting on a card; data-working: working). A name inside code wakes
  // nobody, so it doesn't count.
  mentionedFrom(key) {
    let names = []
    try {
      names = JSON.parse((this.el.form && this.el.form.dataset[key]) || "[]")
    } catch (_e) {
      return []
    }
    const text = maskCode(this.el.value)
    return names.filter(name => {
      const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
      return new RegExp(`(^|[^\\w@#])@${escaped}(?![\\w-])`, "i").test(text)
    })
  },

  // The hint above the composer: one line per named agent that is waiting on
  // a card or working. The @here line goes under the box, in its own slot.
  renderHint() {
    const interrupt = Boolean(this.el.form && this.el.form.dataset.interrupt === "true")
    const awaiting = this.mentionedFrom("awaiting")
    const working = interrupt ? this.mentionedFrom("working").filter(name => !awaiting.includes(name)) : []
    const lines = awaiting
      .map(name =>
        interrupt
          ? `@${name} is waiting on the card above. Your message reaches it once the card is answered.`
          : `@${name} is waiting on the card above. A message will reach it only after it's answered.`
      )
      .concat(working.map(name => `@${name} is working; it will read this after its current step (Alt+Enter: after its turn).`))

    fill(this.hint, lines.length > 0 ? [document.createTextNode(lines.join(" "))] : [])
    fill(this.hereHint, this.draftHasHere() ? this.hereLine(interrupt, awaiting.concat(working)) : [])
  },

  // A live @here, exactly as the highlighter tokenizes the draft: not in code,
  // not in a /delegate or /handoff note (posted with no mentions), and only in
  // an /i note among the commands.
  draftHasHere() {
    const text = this.el.value
    if (!/@here/i.test(text)) return false
    return tokenize(text, draftContext(this.el.form)).some(token => token.kind === "here")
  },

  // "@here wakes 3 agents: @a, @b (working; reads it after its turn), @c.
  // @d is off and won't be woken." `described`: agents a line of their own
  // already speaks for, so their working state isn't repeated here.
  hereLine(interrupt, described) {
    const form = this.el.form
    const roster = this.here()
    const active = roster.filter(agent => agent.active)
    const off = roster.filter(agent => !agent.active)
    const dm = Boolean(form && form.dataset.dm === "true")
    const thread = Boolean(form && form.dataset.thread === "true")
    const span = (className, text) => {
      const el = document.createElement("span")
      el.className = className
      el.textContent = text
      return el
    }

    if (active.length === 0) {
      const where = dm ? "this DM" : "this channel"
      return [span("font-medium text-accent", `@here wakes nobody: no other agents in ${where}.`)]
    }

    const count = active.length === 1 ? "1 agent" : `${active.length} agents`
    const head = thread
      ? `@here wakes all ${count} in ${this.herePlace()}, not just this thread:`
      : `@here wakes ${count}:`
    // In a DM, the user's post steers every working agent when interrupts
    // are on (Canopy.Runtime.Router), @here or not.
    const note = dm && interrupt ? "(working; reads it after its current step)" : "(working; reads it after its turn)"
    const shown = active.length > HERE_NAMES ? active.slice(0, HERE_NAMES - 1) : active
    const nodes = [span("font-medium text-accent", head)]

    shown.forEach((agent, i) => {
      nodes.push(document.createTextNode((i === 0 ? " @" : ", @") + agent.name))
      if (agent.working && !described.some(name => name.toLowerCase() === agent.name.toLowerCase())) {
        nodes.push(document.createTextNode(" "), span("text-base-content/50", note))
      }
    })
    const rest = active.length - shown.length
    nodes.push(document.createTextNode(rest > 0 ? ` and ${rest} more.` : "."))
    off.forEach(agent => nodes.push(document.createTextNode(" "), span("text-base-content/50", `@${agent.name} is off and won't be woken.`)))
    return nodes
  },

  autosize() {
    this.el.style.height = "auto"
    const needed = Math.min(this.el.scrollHeight, AUTO_MAX)
    const height = Math.max(needed, this.manual || 0)
    this.el.style.height = height + "px"
    this.lastAuto = height
    if (this.highlighter) this.highlighter.sync()
  },
}

export default Composer
