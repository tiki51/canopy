// "Archived #name · Undo" after an archive (CanopyWeb.Nav pushes
// "canopy:channel_archived"). The element is phx-update="ignore" and all its
// state lives here, in JS: LiveView re-syncs the root's own data-* attributes
// from the server, and the archive's nav refresh lands in the same moment.
//
// The toast leaves after 6 s; hovering or focusing it holds the clock. A newer
// archive replaces it (Undo then applies to the newer one). From the keyboard
// focus moves to Undo; a mouse archive leaves focus where it was.
import {takeKeyboardArchive} from "../sidebar/archive_origin"

const DELAY = 6000

const UndoToast = {
  mounted() {
    this.channelId = null
    this.timer = null
    this.handleEvent("canopy:channel_archived", ({id, name}) => this.show(id, name))
    this.handlers = {
      mouseenter: () => this.hold(),
      mouseleave: () => this.release(),
      focusin: () => this.hold(),
      focusout: e => { if (!this.el.contains(e.relatedTarget)) this.release() },
      click: e => this.click(e),
      keydown: e => { if (e.key === "Escape") { e.preventDefault(); this.hide(true) } },
    }
    for (const [type, fn] of Object.entries(this.handlers)) this.el.addEventListener(type, fn)
  },

  destroyed() { clearTimeout(this.timer) },

  show(id, name) {
    this.channelId = id
    const keyboard = takeKeyboardArchive()
    this.el.replaceChildren(this.build(name))
    this.release()
    if (keyboard) this.el.querySelector("[data-undo]").focus()
  },

  build(name) {
    const toast = document.createElement("div")
    toast.className = "toast toast-top toast-end z-50"
    const alert = document.createElement("div")
    alert.className = "alert w-80 sm:w-96 max-w-80 sm:max-w-96 bg-base-100 text-wrap shadow-lg"
    alert.setAttribute("role", "status")
    alert.id = "sidebar-undo-toast-alert"

    const icon = document.createElement("span")
    icon.className = "hero-archive-box-mini size-5 shrink-0 opacity-60"
    icon.setAttribute("aria-hidden", "true")

    const text = document.createElement("p")
    text.className = "min-w-0 flex-1"
    const strong = document.createElement("strong")
    strong.textContent = `#${name}`
    text.append("Archived ", strong)

    const undo = document.createElement("button")
    undo.type = "button"
    undo.id = "sidebar-undo-archive"
    undo.dataset.undo = ""
    undo.className = "btn btn-sm btn-ghost text-primary"
    undo.textContent = "Undo"
    undo.setAttribute("aria-label", `Undo archiving #${name}`)

    const close = document.createElement("button")
    close.type = "button"
    close.dataset.close = ""
    close.className = "group cursor-pointer"
    close.setAttribute("aria-label", "Dismiss")
    const x = document.createElement("span")
    x.className = "hero-x-mark size-5 opacity-40 group-hover:opacity-70"
    close.append(x)

    alert.append(icon, text, undo, close)
    toast.append(alert)
    return toast
  },

  click(e) {
    if (e.target.closest("[data-undo]")) {
      const id = this.channelId
      this.hide(false)
      if (id) this.pushEvent("unarchive_channel", {id})
    } else if (e.target.closest("[data-close]")) {
      this.hide(true)
    }
  },

  hold() { clearTimeout(this.timer); this.timer = null },

  release() {
    this.hold()
    if (this.channelId) this.timer = setTimeout(() => this.hide(false), DELAY)
  },

  hide(focusBack) {
    const hadFocus = this.el.contains(document.activeElement)
    this.hold()
    this.channelId = null
    this.el.replaceChildren()
    // the composer on a channel page, else the page itself (#main is
    // focusable on every page)
    if (focusBack && hadFocus) {
      const target = document.querySelector("#composer-form textarea") || document.getElementById("main")
      target?.focus()
    }
  },
}

export default UndoToast
