// The channel composer: Enter sends, Shift+Enter inserts a newline, typing
// `@` opens an autocomplete of agents and teams and `#` one of channels. The
// textarea keeps its text on a failed send; the server pushes "composer:clear"
// on success.
//
// When the draft mentions an agent that is blocked on a question or permission
// card (the form's data-awaiting), a hint says the message will not answer the
// card: the text never round-trips, so the hint is drawn here.
//
// Mentions, channels and commands in the draft are highlighted by a layer
// behind the textarea (composer_highlight.js).
//
// Height: one row by default, growing with its content up to AUTO_MAX. The
// browser's resize handle is off (CSS resize-none); the manual-floor tracking
// below is kept in case it is ever turned back on.
import Highlighter from "../composer_highlight"
import {maskCode} from "../composer_tokens"

const MAX_SUGGESTIONS = 8
const AUTO_MAX = 192

const Composer = {
  mounted() {
    this.index = 0
    this.matches = []
    this.popup = document.querySelector(this.el.dataset.suggestions)

    this.manual = null
    this.lastAuto = null

    // Clicking Reply on a message puts the caret here, so the reply can be
    // typed without a second click.
    this.handleEvent("composer:focus", () => this.el.focus())

    this.handleEvent("composer:clear", () => {
      this.el.value = ""
      this.el.style.height = this.manual ? this.manual + "px" : ""
      this.hide()
      this.renderAwaitingHint()
      if (this.highlighter) this.highlighter.render()
      this.el.focus()
    })

    // The waiting agents change as cards come and go; LiveView patches the
    // form's attribute, never the textarea, so watch the attribute.
    this.hint = document.getElementById("composer-awaiting-hint")
    if (this.el.form) {
      this.formObserver = new MutationObserver(() => this.renderAwaitingHint())
      this.formObserver.observe(this.el.form, {attributes: true, attributeFilter: ["data-awaiting"]})
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
      this.renderAwaitingHint()
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
  },

  // Pasted files (a screenshot from the clipboard arrives as "image.png") go
  // straight to the upload config; text pastes are left to the browser.
  onPaste(e) {
    const files = Array.from((e.clipboardData && e.clipboardData.files) || [])
    if (files.length === 0) return
    e.preventDefault()
    const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "").replace("T", "-")
    const renamed = files.map((file, i) => {
      const generic = /^(image|file|blob)(\.\w+)?$/i.test(file.name) || file.name === ""
      if (!generic) return file
      const ext = (file.name.match(/\.\w+$/) || [file.type ? "." + file.type.split("/")[1] : ""])[0]
      return new File([file], `paste-${stamp}${files.length > 1 ? "-" + (i + 1) : ""}${ext}`, {type: file.type})
    })
    this.upload("files", renamed)
  },

  // The agent, team, and channel lists live on the form, which LiveView keeps
  // current; the textarea itself is never patched. `@` offers agents first,
  // then teams (data-teams), which share the @ namespace.
  candidates(trigger) {
    if (trigger === "#") return this.list("channels")
    return this.list("agents").concat(this.list("teams"))
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
      if (e.key === "Escape") {
        e.preventDefault()
        return this.hide()
      }
    }

    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault()
      if (this.el.value.trim() !== "" && this.el.form) this.el.form.requestSubmit()
    }
  },

  // The `@word` or `#word` immediately before the caret, if any.
  currentMention() {
    const caret = this.el.selectionStart
    const before = this.el.value.slice(0, caret)
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
    this.index = Math.min(this.index, Math.max(this.matches.length - 1, 0))

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
      button.textContent = (this.mention ? this.mention.trigger : "@") + name
      this.popup.appendChild(button)
    })
    this.popup.classList.remove("hidden")
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

  // Agents named in the draft that are waiting on a card in this channel. A
  // name inside code wakes nobody, so it doesn't count.
  awaitingMentioned() {
    let names = []
    try {
      names = JSON.parse((this.el.form && this.el.form.dataset.awaiting) || "[]")
    } catch (_e) {
      return []
    }
    const text = maskCode(this.el.value)
    return names.filter(name => {
      const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
      return new RegExp(`(^|[^\\w@#])@${escaped}(?![\\w-])`, "i").test(text)
    })
  },

  renderAwaitingHint() {
    if (!this.hint) return
    const names = this.awaitingMentioned()
    if (names.length === 0) {
      this.hint.classList.add("hidden")
      this.hint.textContent = ""
      return
    }
    this.hint.textContent = names
      .map(name => `@${name} is waiting on the card above. A message will reach it only after it's answered.`)
      .join(" ")
    this.hint.classList.remove("hidden")
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
