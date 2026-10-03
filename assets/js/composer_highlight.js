// The composer's highlight layer: a copy of the draft behind the textarea, in
// transparent text, with each recognised token wrapped in a
// <span data-kind="…">. Only the chips' backgrounds and underlines show through
// the textarea's transparent background; the glyphs, caret and selection are
// always the textarea's own, so a late or skipped render degrades to a plain
// textarea. Both boxes share their metrics through .composer-text (app.css).
//
// The known names come from data attributes on the form, which LiveView keeps
// current. The hook sits inside an ignored subtree and never sees updated(),
// so a MutationObserver re-renders when membership or thread state changes.
import {tokenize} from "./composer_tokens"

// A huge paste is left unhighlighted until it shrinks.
const MAX_CHARS = 50_000
const SOURCES = [
  "data-agents",
  "data-members",
  "data-team-members",
  "data-channel-refs",
  "data-commands",
  "data-thread",
]

export default class Highlighter {
  constructor(textarea, layer) {
    this.el = textarea
    this.layer = layer
    this.frame = null

    this.onScroll = () => this.syncScroll()
    this.el.addEventListener("scroll", this.onScroll)

    if (this.el.form) {
      this.observer = new MutationObserver(() => this.schedule())
      this.observer.observe(this.el.form, {attributes: true, attributeFilter: SOURCES})
    }

    // Web fonts change line widths once they arrive.
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => this.render())

    this.render()
  }

  // Coalesces bursts (typing, pasting) into one render before the next paint.
  schedule() {
    if (this.frame !== null) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.render()
    })
  }

  render() {
    const text = this.el.value
    const fragment = document.createDocumentFragment()

    if (text.length <= MAX_CHARS) {
      for (const token of tokenize(text, this.context())) {
        if (token.kind === "plain") {
          fragment.appendChild(document.createTextNode(token.text))
        } else {
          const span = document.createElement("span")
          span.dataset.kind = token.kind
          span.textContent = token.text
          fragment.appendChild(span)
        }
      }
      // a trailing newline needs something after it to get a line of its own
      if (text.endsWith("\n")) fragment.appendChild(document.createTextNode("​"))
    }

    this.layer.replaceChildren(fragment)
    this.sync()
  }

  // Size and scroll follow the textarea. clientWidth leaves out its scrollbar,
  // so lines wrap at the same place once the draft overflows.
  sync() {
    this.layer.style.width = this.el.clientWidth + "px"
    this.layer.style.height = this.el.clientHeight + "px"
    this.syncScroll()
  }

  syncScroll() {
    this.layer.scrollTop = this.el.scrollTop
    this.layer.scrollLeft = this.el.scrollLeft
  }

  context() {
    const data = (this.el.form && this.el.form.dataset) || {}
    const read = (value, fallback) => {
      try {
        return value ? JSON.parse(value) : fallback
      } catch (_e) {
        return fallback
      }
    }
    const lower = list => new Set(list.map(name => String(name).toLowerCase()))
    const teams = read(data.teamMembers, {})

    return {
      agents: lower(read(data.agents, [])),
      members: lower(read(data.members, [])),
      teams: new Map(Object.entries(teams).map(([name, members]) => [name.toLowerCase(), members])),
      channels: lower(read(data.channelRefs, [])),
      commands: lower(read(data.commands, [])),
      thread: data.thread === "true",
    }
  }

  destroy() {
    this.el.removeEventListener("scroll", this.onScroll)
    if (this.observer) this.observer.disconnect()
    if (this.frame !== null) cancelAnimationFrame(this.frame)
  }
}
