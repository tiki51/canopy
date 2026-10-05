// The file viewer (CanopyWeb.FileViewer): a modal <dialog> over the channel.
//
// The server renders the dialog with `open`, so a re-render never drops the
// attribute; on mount it is closed and reopened with showModal(), which puts
// it in the top layer, makes the page behind inert and traps focus. Closing
// is always the Close link's patch (Esc, the close button, Back), so the URL
// and the server agree; the server then removes the dialog. When a tile's
// click pushed the viewer's URL, Close goes Back instead, so the history
// doesn't end up with the channel twice.
//
// Everything that needs no server lives here: ← → (the arrow links), zoom and
// pan for images, the image's dimensions, Wrap and the Markdown mode
// (remembered in localStorage), Copy, and in-document #links. Per-file state
// sits in phx-update="ignore" containers keyed by the document id, so it
// survives unrelated re-renders and starts fresh on another file.
import copyText from "../copy_text"
import {openedByLink} from "../file_viewer_links"

const MD_KEY = "canopy:viewer-md-mode"
const WRAP_KEY = "canopy:viewer-wrap"
const STEPS = [0.25, 0.5, 1, 2, 4]

const store = {
  get(key) {
    try { return localStorage.getItem(key) } catch (_e) { return null }
  },
  set(key, value) {
    try { localStorage.setItem(key, value) } catch (_e) { /* private mode: a convenience */ }
  },
}

const FileViewer = {
  mounted() {
    // focus goes back to the tile that opened the viewer
    const active = document.activeElement
    this.returnTo = active && active.matches && active.matches("[data-viewer-link]") ? active.id : null
    this.backOnClose = openedByLink(this.el.dataset.doc, this.el.dataset.message)

    if (this.el.open) this.el.close()
    this.el.showModal()

    this.el.addEventListener("cancel", e => {
      e.preventDefault()
      this.requestClose()
    })
    // a close the page didn't ask for (a second Esc the browser wouldn't let
    // us cancel) still has to reach the URL; the reopen above fires one too,
    // after the dialog is open again, and is ignored
    this.el.addEventListener("close", () => {
      if (!this.el.open) this.requestClose()
    })
    this.el.addEventListener("keydown", e => this.onKeydown(e))
    this.el.addEventListener("click", e => this.onClick(e))

    this.setup()
    // the panel itself, so no button looks picked until someone tabs
    this.el.focus()
  },

  updated() {
    this.closing = false
    if (!this.el.open) this.el.showModal()
    if (this.el.dataset.doc !== this.doc) this.setup()
  },

  destroyed() {
    if (this.el.open) this.el.close()
    const tile =
      (this.returnTo && document.getElementById(this.returnTo)) ||
      document.querySelector(`[data-viewer-link][id$="attachment-${this.message}-${this.doc}"]`)
    if (tile) tile.focus({preventScroll: true})
  },

  requestClose() {
    if (this.closing) return
    this.closing = true
    const close = document.getElementById("file-viewer-close")
    if (close) close.click()
  },

  // -- Per file ----------------------------------------------------------------

  setup() {
    this.doc = this.el.dataset.doc
    this.message = this.el.dataset.message
    this.zoom = null

    const sheet = this.sheet()
    if (sheet) {
      const markdown = sheet.dataset.markdown === "true"
      this.setMode(sheet, markdown ? store.get(MD_KEY) || "preview" : "source", false)
      this.setWrap(sheet, store.get(WRAP_KEY) === "1", false)
    }

    const img = this.image()
    if (img) this.setupImage(img)
  },

  sheet() { return this.el.querySelector("[data-viewer-sheet]") },
  image() { return this.el.querySelector("#file-viewer-image") },

  // -- Keys and clicks ---------------------------------------------------------

  onKeydown(e) {
    if (e.isComposing || e.altKey || e.ctrlKey || e.metaKey) return
    if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
      if (e.target.closest("[data-viewer-mode], input, textarea, select")) return
      // a long unwrapped line scrolls sideways instead
      const body = e.target.closest(".doc-body")
      if (body && body.scrollWidth > body.clientWidth) return
      e.preventDefault()
      this.nav(e.key === "ArrowLeft" ? "prev" : "next")
    } else if (this.image() && (e.key === "+" || e.key === "=")) {
      e.preventDefault()
      this.zoomIn()
    } else if (this.image() && e.key === "-") {
      e.preventDefault()
      this.zoomOut()
    } else if (this.image() && e.key === "0") {
      e.preventDefault()
      this.setZoom(null)
    }
  },

  nav(dir) {
    const link = this.el.querySelector(`#file-viewer-${dir}`)
    if (link && link.getAttribute("aria-disabled") !== "true") link.click()
  },

  onClick(e) {
    if (this.backOnClose && e.target.closest("#file-viewer-close")) {
      e.preventDefault()
      e.stopPropagation()
      this.backOnClose = false
      history.back()
      return
    }
    const zoom = e.target.closest("[data-viewer-zoom]")
    if (zoom) {
      const action = zoom.dataset.viewerZoom
      if (action === "in") this.zoomIn()
      else if (action === "out") this.zoomOut()
      else this.setZoom(this.zoom === null ? 1 : null)
      return
    }
    const mode = e.target.closest("[data-viewer-mode]")
    if (mode) return this.setMode(this.sheet(), mode.dataset.viewerMode, true)
    if (e.target.closest("[data-viewer-wrap]")) {
      const sheet = this.sheet()
      return this.setWrap(sheet, !sheet.hasAttribute("data-wrap"), true)
    }
    const copy = e.target.closest("[data-viewer-copy]")
    if (copy) return this.copy(copy)

    // #links inside a Markdown document scroll to the heading (ids carry a doc- prefix)
    const anchor = e.target.closest('.doc-markdown a[href^="#"]')
    if (anchor) {
      e.preventDefault()
      const id = decodeURIComponent(anchor.getAttribute("href").slice(1))
      const sheet = anchor.closest("[data-viewer-sheet]")
      const target =
        sheet.querySelector(`[id="doc-${CSS.escape(id)}"]`) || sheet.querySelector(`[id="${CSS.escape(id)}"]`)
      if (target) target.scrollIntoView({block: "start", behavior: reducedMotion() ? "auto" : "smooth"})
    }
  },

  // -- Sheet: Markdown mode, Wrap, Copy -------------------------------------------

  setMode(sheet, mode, remember) {
    if (!sheet) return
    sheet.dataset.mode = mode
    sheet.querySelectorAll("[data-viewer-mode]").forEach(button => {
      button.setAttribute("aria-pressed", String(button.dataset.viewerMode === mode))
    })
    if (remember) store.set(MD_KEY, mode)
  },

  setWrap(sheet, on, remember) {
    if (!sheet) return
    if (on) sheet.dataset.wrap = ""
    else delete sheet.dataset.wrap
    const button = sheet.querySelector("[data-viewer-wrap]")
    if (button) button.setAttribute("aria-pressed", String(on))
    if (remember) store.set(WRAP_KEY, on ? "1" : "0")
  },

  copy(button) {
    const raw = this.sheet()?.querySelector("[data-viewer-raw]")
    if (!raw) return
    copyText(raw.content.textContent).then(() => {
      const label = button.querySelector("[data-copy-label]")
      if (!label) return
      label.textContent = "Copied"
      clearTimeout(this.copyTimer)
      this.copyTimer = setTimeout(() => { label.textContent = "Copy" }, 1500)
    }, () => {})
  },

  // -- Image: loading, dimensions, zoom, pan -------------------------------------

  setupImage(img) {
    const stage = img.closest("[data-viewer-stage]")
    const loading = stage.querySelector("[data-viewer-loading]")
    const error = stage.querySelector("[data-viewer-error]")

    const loaded = () => {
      loading.hidden = true
      img.classList.remove("opacity-0")
      const dims = this.el.querySelector("#file-viewer-dims")
      if (dims) {
        dims.textContent = ` · ${img.naturalWidth} × ${img.naturalHeight}`
        dims.hidden = false
      }
    }
    const failed = () => {
      loading.hidden = true
      img.hidden = true
      error.hidden = false
    }
    if (img.complete) img.naturalWidth ? loaded() : failed()
    else {
      img.addEventListener("load", loaded, {once: true})
      img.addEventListener("error", failed, {once: true})
    }

    img.addEventListener("dblclick", () => this.setZoom(this.zoom === null ? 1 : null))

    // above Fit, drag to pan
    stage.addEventListener("pointerdown", e => {
      if (this.zoom === null || e.button !== 0) return
      e.preventDefault()
      stage.setPointerCapture(e.pointerId)
      const start = {x: e.clientX, y: e.clientY, left: stage.scrollLeft, top: stage.scrollTop}
      stage.style.cursor = "grabbing"
      const move = ev => {
        stage.scrollLeft = start.left - (ev.clientX - start.x)
        stage.scrollTop = start.top - (ev.clientY - start.y)
      }
      const up = () => {
        stage.style.cursor = "grab"
        stage.removeEventListener("pointermove", move)
      }
      stage.addEventListener("pointermove", move)
      stage.addEventListener("pointerup", up, {once: true})
      stage.addEventListener("pointercancel", up, {once: true})
    })
  },

  fitScale(img) {
    const stage = img.closest("[data-viewer-stage]")
    if (!img.naturalWidth || !img.naturalHeight) return 1
    return Math.min(1, stage.clientWidth / img.naturalWidth, stage.clientHeight / img.naturalHeight)
  },

  zoomIn() {
    const img = this.image()
    if (!img || !img.naturalWidth) return
    const current = this.zoom === null ? this.fitScale(img) : this.zoom
    const next = STEPS.find(step => step > current + 0.001)
    if (next) this.setZoom(next)
  },

  zoomOut() {
    const img = this.image()
    if (!img || !img.naturalWidth || this.zoom === null) return
    const fit = this.fitScale(img)
    const prev = [...STEPS].reverse().find(step => step < this.zoom - 0.001)
    this.setZoom(prev && prev > fit + 0.001 ? prev : null)
  },

  // null is Fit
  setZoom(scale) {
    const img = this.image()
    if (!img || !img.naturalWidth) return
    const stage = img.closest("[data-viewer-stage]")
    const label = this.el.querySelector("#file-viewer-zoom-label")
    this.zoom = scale

    if (scale === null) {
      Object.assign(img.style, {width: "", height: "", maxWidth: "", maxHeight: ""})
      Object.assign(stage.style, {overflow: "", cursor: ""})
      if (label) label.textContent = "Fit"
      return
    }

    Object.assign(img.style, {
      width: `${Math.round(img.naturalWidth * scale)}px`,
      height: `${Math.round(img.naturalHeight * scale)}px`,
      maxWidth: "none",
      maxHeight: "none",
    })
    Object.assign(stage.style, {overflow: "auto", cursor: "grab"})
    stage.scrollLeft = (stage.scrollWidth - stage.clientWidth) / 2
    stage.scrollTop = (stage.scrollHeight - stage.clientHeight) / 2
    if (label) label.textContent = `${Math.round(scale * 100)}%`
  },
}

function reducedMotion() {
  return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches
}

export default FileViewer
