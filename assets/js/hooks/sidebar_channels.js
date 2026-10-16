// The sidebar's project blocks (CanopyWeb.Sidebar), on #sidebar-projects:
//
//   * the row and section menu (../sidebar/menu.js): the ⋯ buttons,
//     right-click (fine pointers only: iOS never fires it, and on Android it
//     would replace the link menu), or Shift+F10 / the ContextMenu key on a
//     row link or a section header
//   * naming a section in place: the project's + and *New section…* open the
//     editor under the project row, *Rename section* the one in its header.
//     Enter saves, Esc or leaving the field cancels; a refused name stays
//     open with the reason under it
//   * dragging rows onto sections and sections into order (../sidebar/drag.js)
//
// Every change is a Nav event (CanopyWeb.Nav) with a reply; the server's
// render puts things where they belong. Show/hide and attributes on
// server-rendered elements go through the sticky `this.js()`, because the
// sidebar re-renders on every new message anywhere.
import copyText from "../copy_text"
import Menu from "../sidebar/menu"
import SidebarDrag from "../sidebar/drag"
import {markKeyboardArchive} from "../sidebar/archive_origin"

const ROW = "li[data-channel-id]"
const SECTION = "ul[data-section-id]"

const SidebarChannels = {
  mounted() {
    this.menu = new Menu(document.getElementById("sidebar-menu"), {
      onClose: trigger => {
        this.expanded.disconnect()
        if (trigger && trigger.isConnected) this.js().setAttribute(trigger, "aria-expanded", "false")
      },
    })
    // A re-render of the row (a message anywhere) puts the ⋯ button's
    // server-rendered aria-expanded="false" back while its menu is open.
    this.expanded = new MutationObserver(records => {
      for (const {target} of records) {
        if (target.getAttribute("aria-expanded") !== "true") target.setAttribute("aria-expanded", "true")
      }
    })
    this.fine = window.matchMedia("(pointer: fine)")
    this.editing = null
    this.handlers = {
      click: e => this.click(e),
      contextmenu: e => this.contextMenu(e),
      keydown: e => this.key(e),
      submit: e => this.submit(e),
      focusout: e => this.focusOut(e),
    }
    for (const [type, fn] of Object.entries(this.handlers)) this.el.addEventListener(type, fn)
    this.drag = new SidebarDrag(this)
  },

  updated() { this.drag.refresh() },

  destroyed() {
    for (const [type, fn] of Object.entries(this.handlers)) this.el.removeEventListener(type, fn)
    this.expanded.disconnect()
    clearTimeout(this.copyTimer)
    this.menu.destroy()
    this.drag.destroy()
  },

  closeMenu() { this.menu.hide({focus: false}) },

  // -- Opening menus ---------------------------------------------------------

  click(e) {
    const add = e.target.closest("[data-new-section]")
    if (add) {
      this.openEditor(this.createEditor(add.dataset.newSection), "", add)
      return
    }
    const more = e.target.closest("[data-menu]")
    if (more) {
      e.preventDefault()
      this.openMenu(more, {trigger: more, anchor: more})
    }
  },

  contextMenu(e) {
    if (!this.fine.matches || e.target.closest("[data-section-editor]")) return
    const target = e.target.closest(`${ROW}, [data-section-header]`)
    if (!target) return
    e.preventDefault()
    const at = {x: e.clientX, y: e.clientY}
    // macOS fires contextmenu on mousedown: opened now, the popover's light
    // dismiss would close it on the pointerup that follows. Wait for it.
    if (e.buttons === 0) { this.openMenu(target, {at}); return }
    window.addEventListener("pointerup", () => setTimeout(() => {
      if (target.isConnected) this.openMenu(target, {at})
    }), {once: true, capture: true})
  },

  key(e) {
    if (e.key === "Escape" && this.editing && this.editing.wrapper.contains(e.target)) {
      e.preventDefault()
      this.closeEditor(true)
      return
    }
    if (!(e.key === "ContextMenu" || (e.shiftKey && e.key === "F10"))) return
    const on = e.target.closest('a[id^="sidebar-channel-"], [data-section-handle]')
    if (!on) return
    e.preventDefault()
    this.openMenu(on, {anchor: on.closest(`${ROW}, [data-section-header]`)})
  },

  // `from` is anything inside a row or a section header.
  openMenu(from, {trigger, anchor, at}) {
    const row = from.closest(ROW)
    const header = from.closest("[data-section-header]")
    let spec
    if (row) spec = this.channelMenu(row)
    else if (header) spec = this.sectionMenu(header.closest(SECTION))
    else return
    const button = trigger || (row || header).querySelector("[data-menu]")
    // a Copy link still counting down belongs to the menu being replaced
    clearTimeout(this.copyTimer)
    this.menu.open({...spec, anchor, at, trigger: button})
    if (button) {
      this.js().setAttribute(button, "aria-expanded", "true")
      this.expanded.observe(button, {attributes: true, attributeFilter: ["aria-expanded"]})
    }
  },

  channelMenu(row) {
    const id = row.dataset.channelId
    const current = row.dataset.sectionId || ""
    const project = row.closest("[data-repo-id]")
    const link = this.rowLink(id)
    const sections = [...project.querySelectorAll(SECTION)].map(s => ({id: s.dataset.sectionId, name: s.dataset.sectionName}))
    const move = [
      ...sections.map(s => ({label: s.name, checked: s.id === current, run: () => this.moveChannel(row, s.id)})),
      ...(sections.length ? [{separator: true}] : []),
      {
        label: "New section…",
        icon: "hero-plus-mini",
        run: () => this.openEditor(this.createEditor(project.dataset.repoId), "", link, {moveChannel: id}),
      },
      {label: "Remove from section", icon: "hero-arrow-uturn-up-mini", disabled: !current, run: () => this.moveChannel(row, "")},
    ]
    const items = [
      {label: "Move to section", icon: "hero-folder-arrow-down-mini", submenu: move},
      {
        label: "Mark as read",
        icon: "hero-envelope-open-mini",
        disabled: row.dataset.unread !== "true",
        run: () => this.pushEvent("mark_channel_read", {id}, () => this.focusRow(id)),
      },
      {
        label: "Copy link",
        icon: "hero-link-mini",
        run: (_kb, el) => {
          copyText(new URL(`/channels/${id}`, window.location.origin).href)
          el.querySelector(".truncate").textContent = "Copied"
          this.copyTimer = setTimeout(() => this.menu.hide(), 600)
          return "keep"
        },
      },
    ]
    if (row.dataset.archived !== "true") {
      items.push({separator: true}, {
        label: "Archive channel",
        icon: "hero-archive-box-arrow-down-mini",
        run: kb => this.archive(row, kb),
      })
    }
    return {items, label: `#${row.dataset.name}`, back: link}
  },

  sectionMenu(section) {
    const id = section.dataset.sectionId
    const all = [...section.parentElement.querySelectorAll(`:scope > ${SECTION}`)]
    const at = all.indexOf(section)
    const toggle = this.sectionToggle(id)
    const move = index => this.pushEvent("move_section", {id, index}, () => this.focusSection(id))
    return {
      label: `Section ${section.dataset.sectionName}`,
      back: toggle,
      items: [
        {label: "Rename section", run: () => this.openEditor(document.getElementById(`sidebar-rename-section-${id}`), section.dataset.sectionName, toggle)},
        {label: "Move up", disabled: at <= 0, run: () => move(at - 1)},
        {label: "Move down", disabled: at === all.length - 1, run: () => move(at + 1)},
        {separator: true},
        {label: "Delete section", danger: true, run: () => this.deleteSection(section)},
        {note: "Its channels move back to the top of the project. Nothing is archived."},
      ],
    }
  },

  // -- Actions ---------------------------------------------------------------

  moveChannel(row, sectionId) {
    const id = row.dataset.channelId
    if ((row.dataset.sectionId || "") === sectionId) { this.focusRow(id); return }
    this.pushEvent("move_channel", {id, section_id: sectionId}, () => this.focusRow(id))
  },

  archive(row, viaKeyboard) {
    const id = row.dataset.channelId
    const fallback = this.neighbour(row)
    if (viaKeyboard) markKeyboardArchive()
    this.pushEvent("archive_channel", {id}, reply => {
      // from the keyboard the Undo toast takes focus; otherwise stay on the
      // row, or its neighbour once it folded into "N archived"
      if (!viaKeyboard && reply && reply.ok) this.focusRow(id, fallback)
    })
  },

  deleteSection(section) {
    const project = section.closest("[data-repo-id]")
    const first = section.querySelector(`${ROW} a`)
    this.pushEvent("delete_section", {id: section.dataset.sectionId}, () => {
      requestAnimationFrame(() => {
        const target = (first && first.isConnected && first) || project.querySelector(`${ROW} a`) || project.querySelector("[data-new-section]")
        if (target) target.focus()
      })
    })
  },

  // -- Naming in place -------------------------------------------------------

  createEditor(repoId) { return document.getElementById(`sidebar-new-section-${repoId}`) },

  openEditor(wrapper, value, returnTo, extra = {}) {
    if (!wrapper) return
    if (this.editing) this.closeEditor(false)
    const input = wrapper.querySelector("input")
    const error = wrapper.querySelector('[role="alert"]')
    // not js().show/hide: those test visibility now and act a frame later,
    // so a hide and a show in one frame (+ twice) cancel out. Class ops
    // queue in order, and the last one wins.
    this.js().removeClass(wrapper, "hidden")
    input.value = value
    error.textContent = ""
    this.editing = {wrapper, input, error, returnTo, busy: false, ...extra}
    requestAnimationFrame(() => { input.focus(); input.select() })
  },

  closeEditor(focusBack) {
    const editing = this.editing
    if (!editing) return
    this.editing = null
    this.js().addClass(editing.wrapper, "hidden")
    editing.input.value = ""
    editing.error.textContent = ""
    if (focusBack && editing.returnTo && editing.returnTo.isConnected) editing.returnTo.focus()
  },

  focusOut(e) {
    const editing = this.editing
    if (!editing || editing.busy || !editing.wrapper.contains(e.target)) return
    if (e.relatedTarget && editing.wrapper.contains(e.relatedTarget)) return
    this.closeEditor(false)
  },

  submit(e) {
    const wrapper = e.target.closest("[data-section-editor]")
    if (!wrapper) return
    e.preventDefault()
    const editing = this.editing
    if (!editing || editing.wrapper !== wrapper || editing.busy) return
    const name = editing.input.value.trim()
    if (name === "") { this.closeEditor(true); return }

    const create = wrapper.dataset.sectionEditor === "create"
    const [event, params] = create
      ? ["create_section", {repository_id: wrapper.dataset.repoId, name}]
      : ["rename_section", {id: wrapper.dataset.sectionId, name}]
    editing.busy = true
    this.pushEvent(event, params, reply => {
      editing.busy = false
      if (!reply || !reply.ok) {
        editing.error.textContent = (reply && reply.error) || "That name could not be saved."
        editing.input.focus()
        return
      }
      const id = create ? reply.id : wrapper.dataset.sectionId
      if (this.editing === editing) this.closeEditor(false)
      if (create && editing.moveChannel) {
        const channel = editing.moveChannel
        this.pushEvent("move_channel", {id: channel, section_id: id}, () => this.focusRow(channel))
      } else {
        this.focusSection(id)
      }
    })
  },

  // -- Focus -----------------------------------------------------------------

  rowLink(id) { return document.getElementById(`sidebar-channel-${id}`) },
  sectionToggle(id) { return document.getElementById(`sidebar-section-toggle-${id}`) },

  // The next visible row, else the previous one: where focus goes when this
  // row leaves the list.
  neighbour(row) {
    const rows = [...this.el.querySelectorAll(ROW)].filter(r => r.offsetParent !== null)
    const at = rows.indexOf(row)
    const other = rows[at + 1] || rows[at - 1]
    return other && other.dataset.channelId
  },

  // After the reply's render: the row, or its collapsed section's header,
  // or the fallback row.
  focusRow(id, fallback) {
    requestAnimationFrame(() => {
      const link = this.rowLink(id)
      if (link && link.offsetParent !== null && link.closest(ROW)) { link.focus(); return }
      const section = link && link.closest(SECTION)
      if (section && link.closest(ROW)) { this.sectionToggle(section.dataset.sectionId)?.focus(); return }
      const other = fallback && this.rowLink(fallback)
      if (other) other.focus()
    })
  },

  focusSection(id) {
    requestAnimationFrame(() => { this.sectionToggle(id)?.focus() })
  },
}

export default SidebarChannels
