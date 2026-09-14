// The channel composer: Enter sends, Shift+Enter inserts a newline, typing
// `@` opens an autocomplete of agents and `#` one of channels. The textarea keeps
// its text on a failed send; the server pushes "composer:clear" on success.
//
// Height: one row by default, growing with its content up to AUTO_MAX. The
// browser's resize handle is off (CSS resize-none); the manual-floor tracking
// below is kept in case it is ever turned back on.
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
      this.el.focus()
    })

    // A height we did not set ourselves is the reader dragging the handle.
    this.observer = new ResizeObserver(() => {
      const height = this.el.offsetHeight
      if (this.lastAuto !== null && Math.abs(height - this.lastAuto) > 2) this.manual = height
    })
    this.observer.observe(this.el)

    this.el.addEventListener("keydown", e => this.onKeydown(e))
    this.el.addEventListener("input", () => {
      this.autosize()
      this.refresh()
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

  // The agent and channel lists live on the form, which LiveView keeps
  // current; the textarea itself is never patched.
  candidates(trigger) {
    const key = trigger === "#" ? "channels" : "agents"
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
  },

  autosize() {
    this.el.style.height = "auto"
    const needed = Math.min(this.el.scrollHeight, AUTO_MAX)
    const height = Math.max(needed, this.manual || 0)
    this.el.style.height = height + "px"
    this.lastAuto = height
  },
}

export default Composer
