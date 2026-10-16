// Dragging in the sidebar (SortableJS, vendored for the playbook builder).
//
// Rows: one Sortable per drop zone, the unsectioned <ul> of a project and
// each section's <ul> (its header is the first item, so dropping on the
// header counts, and a collapsed section is still a target). Sections: one
// Sortable per project on #sidebar-sections-<repo>, by the header.
//
// LiveView stays the only owner of the DOM: on drop the dragged element goes
// back exactly where it was (its recorded parent and next sibling), and the
// change is pushed (`move_channel`, `move_section`); the next render puts it
// in place. State the server renders over (the target highlight, the
// project's data-dragging) is set through the hook's sticky `js()`.
//
// A row lands in the zone last under the pointer, not Sortable's `e.to`:
// Sortable only moves the row into a list beside a visible item, so a
// collapsed section's header would leave it in a list it passed on the way,
// and a patch mid-drag can put it back where it started. Leaving every zone
// for a gap in the project keeps the last one; leaving the project clears it.
//
// Either drag changes something only on a `drop`: Sortable's onEnd also fires
// for Esc and for a drop elsewhere on the page, which change nothing. A row
// needs the drop in its project, a section anywhere in the sidebar.
//
// Off on coarse pointers, where a long press fights scrolling and link
// previews; the menu does everything drag does.
import Sortable from "../../vendor/sortable"

const ZONE = "ul[data-section-id], [data-drop-section]"

export default class SidebarDrag {
  constructor(hook) {
    this.hook = hook
    this.sorters = new Map()
    this.row = null
    this.dropped = false
    this.fine = window.matchMedia("(pointer: fine)")
    this.onPointer = () => this.refresh()
    this.fine.addEventListener("change", this.onPointer)
    this.onDragOver = e => this.dragOver(e)
    this.onDrop = e => this.drop(e)
    // capture: Sortable stops dragover and drop from bubbling out of its lists.
    // dragover on the whole page, so leaving the project clears the highlight.
    document.addEventListener("dragover", this.onDragOver, true)
    hook.el.addEventListener("drop", this.onDrop, true)
    this.refresh()
  }

  destroy() {
    this.fine.removeEventListener("change", this.onPointer)
    document.removeEventListener("dragover", this.onDragOver, true)
    this.hook.el.removeEventListener("drop", this.onDrop, true)
    for (const sorter of this.sorters.values()) sorter.destroy()
    this.sorters.clear()
  }

  // Called on mount and after every patch: drop sorters whose element left,
  // create them for zones that appeared (a new section, a new project).
  refresh() {
    for (const [el, sorter] of this.sorters) {
      if (!el.isConnected || !this.fine.matches) { sorter.destroy(); this.sorters.delete(el) }
    }
    if (!this.fine.matches) return
    for (const project of this.hook.el.querySelectorAll(":scope > [data-repo-id]")) {
      const repo = project.dataset.repoId
      const list = project.querySelector(`#sidebar-sections-${CSS.escape(repo)}`)
      const top = project.querySelector(`#sidebar-top-${CSS.escape(repo)}`)
      if (!list || !top) continue
      const sections = [...list.querySelectorAll(":scope > ul[data-section-id]")]
      if (sections.length === 0) continue
      for (const zone of [top, ...sections]) {
        if (!this.sorters.has(zone)) this.sorters.set(zone, this.rows(zone, repo, project))
      }
      if (!this.sorters.has(list)) this.sorters.set(list, this.sections(list, repo))
    }
  }

  rows(zone, repo, project) {
    return Sortable.create(zone, {
      group: `channels-${repo}`,
      sort: false,
      draggable: "li[data-channel-id]",
      filter: ".row-actions, [data-section-editor]",
      preventOnFilter: false,
      ghostClass: "sidebar-ghost",
      onStart: e => {
        this.row = {item: e.item, parent: e.item.parentNode, next: e.item.nextSibling, from: zone, project, zone, over: null}
        this.dropped = false
        this.hook.js().setAttribute(project, "data-dragging", "")
        this.hook.closeMenu()
      },
      onEnd: e => this.dropRow(e),
    })
  }

  sections(list, repo) {
    let start = null
    return Sortable.create(list, {
      group: `sections-${repo}`,
      draggable: "ul[data-section-id]",
      handle: "[data-section-handle]",
      filter: "[data-menu], [data-section-editor]",
      preventOnFilter: false,
      ghostClass: "sidebar-ghost",
      animation: 150,
      onStart: e => {
        start = {item: e.item, parent: e.item.parentNode, next: e.item.nextSibling}
        this.dropped = false
        this.hook.closeMenu()
      },
      onEnd: e => {
        if (!start) return
        const {item, parent, next} = start
        start = null
        // Sortable sorts live: this also undoes the preview of a cancelled drag
        restore(item, parent, next)
        if (!this.dropped || e.oldDraggableIndex === e.newDraggableIndex) return
        this.hook.pushEvent("move_section", {id: item.dataset.sectionId, index: e.newDraggableIndex})
      },
    })
  }

  // The zone under the pointer is where the row will land, and gets the
  // highlight; the zone the row came from doesn't (dropping there changes
  // nothing). A gap in the project keeps the last zone, lit; outside the
  // project there is none.
  dragOver(e) {
    const drag = this.row
    if (!drag) return
    const inside = e.target instanceof Element && drag.project.contains(e.target)
    const zone = inside ? e.target.closest(ZONE) : null
    if (inside && !zone) return
    drag.zone = zone
    this.highlight(zone === drag.from ? null : zone)
  }

  // Comes before Sortable's onEnd, which follows the drop.
  drop(e) {
    this.dropped = true
    if (this.row) this.dragOver(e)
  }

  highlight(zone) {
    const drag = this.row
    if (zone === drag.over) return
    if (drag.over && drag.over.isConnected) this.hook.js().removeClass(drag.over, "sidebar-drop-target")
    if (zone) this.hook.js().addClass(zone, "sidebar-drop-target")
    drag.over = zone
  }

  dropRow(e) {
    const drag = this.row
    if (!drag) return
    this.highlight(null)
    this.row = null
    restore(drag.item, drag.parent, drag.next)
    this.hook.js().removeAttribute(drag.project, "data-dragging")
    if (!this.dropped || !drag.zone) return

    const target = (drag.zone.isConnected && drag.zone) || (e.to && e.to.closest(ZONE))
    if (!target || target === drag.from) return
    const sectionId = target.dataset.sectionId || ""
    if ((drag.item.dataset.sectionId || "") === sectionId) return
    this.hook.pushEvent("move_channel", {id: drag.item.dataset.channelId, section_id: sectionId})
  }
}

function restore(item, parent, next) {
  if (!parent.isConnected) return
  parent.insertBefore(item, next && next.parentNode === parent ? next : null)
}
