// The channel composer: Enter sends, Shift+Enter inserts a newline, and typing
// `@` opens an autocomplete of the channel's member agents. The textarea keeps
// its text on a failed send; the server pushes "composer:clear" on success.
const MAX_SUGGESTIONS = 8

const Composer = {
  mounted() {
    this.index = 0
    this.matches = []
    this.popup = document.querySelector(this.el.dataset.suggestions)

    this.handleEvent("composer:clear", () => {
      this.el.value = ""
      this.el.style.height = ""
      this.hide()
      this.el.focus()
    })

    this.el.addEventListener("keydown", e => this.onKeydown(e))
    this.el.addEventListener("input", () => {
      this.autosize()
      this.refresh()
    })
    this.el.addEventListener("blur", () => setTimeout(() => this.hide(), 150))

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

  members() {
    try {
      return JSON.parse(this.el.dataset.members || "[]")
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

  // The `@word` immediately before the caret, if any.
  currentMention() {
    const caret = this.el.selectionStart
    const before = this.el.value.slice(0, caret)
    const match = before.match(/(?:^|[^\w@])@([a-z0-9_-]*)$/i)
    if (!match) return null
    return {start: caret - match[1].length - 1, query: match[1].toLowerCase(), caret}
  },

  refresh() {
    const mention = this.currentMention()
    if (!mention) return this.hide()

    this.mention = mention
    this.matches = this.members()
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
      button.textContent = "@" + name
      this.popup.appendChild(button)
    })
    this.popup.classList.remove("hidden")
  },

  choose(name) {
    const mention = this.mention || this.currentMention()
    if (!mention) return this.hide()
    const value = this.el.value
    const insert = "@" + name + " "
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

  autosize() {
    this.el.style.height = "auto"
    this.el.style.height = Math.min(this.el.scrollHeight, 192) + "px"
  },
}

export default Composer
