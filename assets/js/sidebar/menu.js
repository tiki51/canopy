// The sidebar's row and section menu: one `popover="auto"` element in the
// layout (#sidebar-menu, phx-update="ignore"), filled on each open. Top layer,
// so the scrolling sidebar can't clip it, and light dismiss for free. A
// submenu is a popover nested inside it, so opening it keeps the menu up.
//
// Keys follow the WAI-ARIA menu pattern: ↑/↓ (wrapping), Home/End, → or Enter
// into a submenu, ← or Esc out of it, Enter/Space to choose, Esc or Tab to
// close, and a first letter jumps to the next item starting with it.
//
// An item is {label, run(viaKeyboard, el), disabled, danger, checked, icon,
// submenu: [items]}, or {separator: true}, or {note: "text"}. `run` returning
// "keep" leaves the menu open (Copy link closes itself after "Copied").
const ITEM = '[role^="menuitem"]'

export default class Menu {
  constructor(root, {onClose} = {}) {
    this.root = root
    this.onClose = onClose
    this.sub = document.createElement("div")
    this.sub.id = "sidebar-submenu"
    this.sub.setAttribute("popover", "auto")
    this.sub.setAttribute("role", "menu")
    this.sub.className = "sidebar-menu"
    this.subParent = null

    this.handlers = {
      keydown: e => this.key(e),
      click: e => this.click(e),
      pointerover: e => this.hover(e),
    }
    for (const [type, fn] of Object.entries(this.handlers)) root.addEventListener(type, fn)
    // `beforetoggle` is synchronous; `toggle` is queued, and a hide and show
    // in the same task (reopening on another ⋯) merge into one "open" toggle.
    // So the trigger is let go of before hiding, and focus is sorted after.
    this.onBeforeToggle = e => { if (e.newState === "closed") this.closing() }
    this.onToggle = e => { if (e.newState === "closed") this.closed() }
    this.onSubToggle = e => { if (e.newState === "closed") this.subClosed() }
    root.addEventListener("beforetoggle", this.onBeforeToggle)
    root.addEventListener("toggle", this.onToggle)
    this.sub.addEventListener("toggle", this.onSubToggle)
  }

  destroy() {
    for (const [type, fn] of Object.entries(this.handlers)) this.root.removeEventListener(type, fn)
    this.root.removeEventListener("beforetoggle", this.onBeforeToggle)
    this.root.removeEventListener("toggle", this.onToggle)
    this.sub.removeEventListener("toggle", this.onSubToggle)
    this.hide({focus: false})
  }

  isOpen() { return this.root.matches(":popover-open") }

  // `anchor` is an element to open beside, or `at` a pointer position.
  // `trigger` is the ⋯ button whose aria-expanded follows the menu; `back` is
  // where focus goes when the menu closes without an action.
  open({items, label, anchor, at, trigger, back}) {
    if (this.isOpen()) this.hide({focus: false})
    this.trigger = trigger || null
    this.back = back || null
    this.returnFocus = true
    this.root.setAttribute("aria-label", label)
    this.build(this.root, items)
    this.root.append(this.sub)
    this.root.showPopover()
    this.place(this.root, anchor ? anchor.getBoundingClientRect() : null, at)
    const first = this.items(this.root)[0]
    if (first) first.focus()
  }

  // Closes the menu. With `focus: false` the caller moves focus itself (an
  // action that changes the sidebar).
  hide({focus = true} = {}) {
    this.returnFocus = focus
    if (this.sub.matches(":popover-open")) this.sub.hidePopover()
    if (this.isOpen()) this.root.hidePopover()
  }

  closing() {
    const trigger = this.trigger
    this.trigger = null
    if (this.onClose) this.onClose(trigger)
  }

  closed() {
    if (this.isOpen()) return
    const active = document.activeElement
    const lost = !active || active === document.body || this.root.contains(active)
    if (this.returnFocus && lost && this.back && this.back.isConnected) this.back.focus()
  }

  // A list with radio items keeps their check column for every item, so the
  // labels line up (an item's icon then sits in that column).
  build(container, items) {
    container.replaceChildren()
    const column = items.some(i => i.checked !== undefined)
    for (const item of items) container.append(this.node(item, column))
  }

  node(item, column = false) {
    if (item.separator) {
      const hr = document.createElement("div")
      hr.setAttribute("role", "separator")
      return hr
    }
    if (item.note) {
      const p = document.createElement("p")
      p.className = "menu-note"
      p.textContent = item.note
      return p
    }
    const el = document.createElement("div")
    const radio = item.checked !== undefined
    el.setAttribute("role", radio ? "menuitemradio" : "menuitem")
    el.tabIndex = -1
    if (radio) el.setAttribute("aria-checked", String(!!item.checked))
    if (item.disabled) el.setAttribute("aria-disabled", "true")
    if (item.danger) el.dataset.danger = ""
    if (item.submenu) {
      el.setAttribute("aria-haspopup", "menu")
      el.setAttribute("aria-expanded", "false")
      el.setAttribute("aria-controls", this.sub.id)
    }
    if (radio || column) {
      const check = document.createElement("span")
      check.className = "menu-check"
      check.setAttribute("aria-hidden", "true")
      if (radio) check.textContent = item.checked ? "✓" : ""
      else if (item.icon) check.className = `menu-check ${item.icon} size-4 opacity-70`
      el.append(check)
    } else if (item.icon) {
      const icon = document.createElement("span")
      icon.className = `${item.icon} size-4 shrink-0 opacity-70`
      icon.setAttribute("aria-hidden", "true")
      el.append(icon)
    }
    const label = document.createElement("span")
    label.className = "min-w-0 flex-1 truncate"
    label.textContent = item.label
    el.append(label)
    if (item.submenu) {
      const caret = document.createElement("span")
      caret.className = "hero-chevron-right-mini size-4 shrink-0 opacity-60"
      caret.setAttribute("aria-hidden", "true")
      el.append(caret)
    }
    el._item = item
    return el
  }

  items(container) { return [...container.children].filter(c => c.matches(ITEM)) }

  // Beside a rect (to its right, flipping left), or at a pointer position,
  // kept inside the viewport.
  place(el, rect, at) {
    const w = el.offsetWidth, h = el.offsetHeight
    const vw = window.innerWidth, vh = window.innerHeight
    let left, top
    if (rect) {
      left = rect.right + 4
      if (left + w > vw - 4) left = Math.max(4, rect.left - w - 4)
      top = rect.top
    } else {
      left = at ? at.x : 4
      top = at ? at.y : 4
      if (left + w > vw - 4) left = Math.max(4, left - w)
    }
    if (top + h > vh - 4) top = Math.max(4, vh - h - 4)
    el.style.left = `${left}px`
    el.style.top = `${top}px`
  }

  openSub(parent, focusFirst) {
    if (this.subParent === parent && this.sub.matches(":popover-open")) {
      if (focusFirst) this.items(this.sub)[0]?.focus()
      return
    }
    this.closeSub(false)
    this.build(this.sub, parent._item.submenu)
    this.sub.setAttribute("aria-label", parent._item.label)
    this.subParent = parent
    parent.setAttribute("aria-expanded", "true")
    this.sub.showPopover()
    const rect = parent.getBoundingClientRect()
    this.place(this.sub, {left: rect.left - 4, right: rect.right + 4, top: rect.top - 5})
    if (focusFirst) this.items(this.sub)[0]?.focus()
  }

  closeSub(focusParent) {
    const parent = this.subParent
    if (this.sub.matches(":popover-open")) this.sub.hidePopover()
    if (focusParent && parent && parent.isConnected) parent.focus()
  }

  subClosed() {
    if (this.subParent) this.subParent.setAttribute("aria-expanded", "false")
    this.subParent = null
  }

  activate(el, viaKeyboard) {
    const item = el && el._item
    if (!item || item.disabled) return
    if (item.submenu) { this.openSub(el, true); return }
    if (item.run(viaKeyboard, el) !== "keep") this.hide({focus: false})
  }

  click(e) {
    const el = e.target.closest(ITEM)
    if (!el) return
    // a click with detail 0 came from the keyboard (Enter on a focused item)
    this.activate(el, e.detail === 0)
  }

  // Not for touch: a tap's hover would open the submenu over the item on a
  // narrow screen, and the tap's click would then land on a submenu entry.
  hover(e) {
    if (e.pointerType === "touch") return
    const el = e.target.closest(ITEM)
    if (!el) return
    if (el.parentElement === this.root) {
      if (el._item.submenu) this.openSub(el, false)
      else this.closeSub(false)
    }
    el.focus()
  }

  key(e) {
    const container = e.target.closest('[role="menu"]')
    if (!container) return
    const items = this.items(container)
    const current = e.target.closest(ITEM)
    const at = items.indexOf(current)
    const go = i => items[(i + items.length) % items.length]?.focus()
    const inSub = container === this.sub

    switch (e.key) {
      case "ArrowDown": go(at + 1); break
      case "ArrowUp": go(at < 0 ? -1 : at - 1); break
      case "Home": go(0); break
      case "End": go(-1); break
      case "ArrowRight":
        if (current && current._item.submenu) this.openSub(current, true)
        break
      case "ArrowLeft":
        if (inSub) this.closeSub(true)
        break
      case "Escape":
        if (inSub) this.closeSub(true)
        else this.hide()
        break
      case "Tab":
        this.hide()
        break
      case "Enter":
      case " ":
        this.activate(current, true)
        break
      default:
        if (e.key.length === 1 && /\S/.test(e.key) && !e.metaKey && !e.ctrlKey && !e.altKey) {
          const ch = e.key.toLowerCase()
          const order = [...items.slice(at + 1), ...items.slice(0, at + 1)]
          const hit = order.find(i => i._item.label.toLowerCase().startsWith(ch))
          if (hit) hit.focus()
          break
        }
        return
    }
    e.preventDefault()
    e.stopPropagation()
  }
}
