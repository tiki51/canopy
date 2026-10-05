// Clickable cards. A `data-card` element opens its `data-card-link` (the
// card's own link, which stays the focus and Enter target) when a click lands
// on the card itself rather than on one of its controls: anything matching
// CONTROLS, or inside one, keeps behaving as it does. A click that ends a drag
// (a text selection) or is the second of a double-click does nothing, so text
// in the card can still be selected and copied; nor does one that closes an
// open dropdown menu (focus was in a `.dropdown` when the button went down).
//
// A plain click goes through the link, so LiveView navigates as usual.
// ⌘/Ctrl/Shift-click and middle-click open the link in a new tab, as they
// would on the link. Listening on the document covers streamed and patched
// cards without a hook per card.
const CONTROLS = [
  "a", "button", "input", "select", "textarea", "label", "summary", "details",
  "[contenteditable]", "[role=menu]", "[role=menuitem]", ".dropdown", "[data-card-ignore]",
].join(", ")

// Where the button went down (a click more than a few pixels away ends a
// drag) and whether a dropdown menu was open then.
let down = {x: 0, y: 0, menu: false}
document.addEventListener("mousedown", e => {
  const focused = document.activeElement
  down = {x: e.clientX, y: e.clientY, menu: !!(focused && focused.closest && focused.closest(".dropdown"))}
}, true)

function cardLink(e) {
  if (e.defaultPrevented || e.detail > 1 || !(e.target instanceof Element)) return null
  if (down.menu || Math.hypot(e.clientX - down.x, e.clientY - down.y) > 4) return null
  const card = e.target.closest("[data-card]")
  if (!card) return null
  const control = e.target.closest(CONTROLS)
  if (control && card.contains(control)) return null
  return card.querySelector("a[data-card-link]")
}

document.addEventListener("click", e => {
  if (e.button !== 0) return
  const link = cardLink(e)
  if (!link) return
  if (e.metaKey || e.ctrlKey || e.shiftKey) {
    e.preventDefault()
    window.open(link.href, "_blank", "noopener")
  } else {
    link.click()
  }
})

document.addEventListener("auxclick", e => {
  if (e.button !== 1) return
  const link = cardLink(e)
  if (!link) return
  e.preventDefault()
  window.open(link.href, "_blank", "noopener")
})
