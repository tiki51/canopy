// Attachment tiles (CanopyWeb.TimelineComponents.attachments/1) link to
// /channels/:id?file=…&in=…, which opens the file viewer. Whatever else the
// URL holds (an open thread, an activity panel, a pointed-at message) should
// stay, but tiles live in streamed messages the server doesn't re-render when
// the URL changes. So the href is completed here, in the capture phase, just
// before LiveView (or the browser, for ⌘-click, middle-click and the context
// menu) reads it. `attach` is dropped: it would put a file in the composer again.
//
// A plain click pushes the viewer's URL onto the history; the viewer's moves
// replace it. openedByLink() tells the viewer so, and its Close then goes
// Back instead of leaving a second copy of the channel's URL behind. The
// click is remembered by file and message, so one that opened nothing (a file
// no longer in the conversation) can't vouch for a viewer opened later.
let opened = null

export function openedByLink(file, message) {
  const was = opened
  opened = null
  return was !== null && was.file === file && was.in === message
}

function complete(e) {
  const link = e.target && e.target.closest && e.target.closest("a[data-viewer-link]")
  if (!link) return
  const target = new URL(link.getAttribute("href"), window.location.href)
  if (e.type === "click" && e.button === 0 && !(e.metaKey || e.ctrlKey || e.shiftKey || e.altKey)) {
    opened = {file: target.searchParams.get("file"), in: target.searchParams.get("in")}
  }
  if (target.pathname !== window.location.pathname) return
  const url = new URL(window.location.href)
  url.searchParams.delete("attach")
  url.searchParams.set("file", target.searchParams.get("file"))
  url.searchParams.set("in", target.searchParams.get("in"))
  link.setAttribute("href", url.pathname + url.search)
}

for (const type of ["click", "auxclick", "contextmenu"]) {
  document.addEventListener(type, complete, true)
}
