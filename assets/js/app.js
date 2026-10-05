// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/canopy"
import topbar from "../vendor/topbar"
import Composer from "./hooks/composer"
import TimelineScroll from "./hooks/timeline_scroll"
import Pref from "./hooks/pref"
import AutoDismiss from "./hooks/auto_dismiss"
import SidebarScroll from "./hooks/sidebar_scroll"
import SidePanel from "./hooks/side_panel"
import CopyLink from "./hooks/copy_link"
import CommandPalette from "./hooks/command_palette"
import SearchNav from "./hooks/search_nav"
import Notifier from "./hooks/notifier"
import HeaderFit from "./hooks/header_fit"
import FileViewer from "./hooks/file_viewer"
import copyText from "./copy_text"
import PlaybookBuilder from "./hooks/playbook_builder"
import notifier from "./notify"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    Composer,
    TimelineScroll,
    Pref,
    AutoDismiss,
    SidebarScroll,
    SidePanel,
    CopyLink,
    CommandPalette,
    SearchNav,
    Notifier,
    HeaderFit,
    FileViewer,
    PlaybookBuilder,
  },
})

// Desktop notifications (./notify.js), one per tab. Settings → Notifications
// and the command palette reach it through this handle.
window.canopyNotifier = notifier

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Custom confirmation: any control with data-canopy-confirm="message" (and an
// optional data-canopy-confirm-title / data-canopy-confirm-label) opens the
// dialog in the root layout instead of the browser's confirm box. Confirming
// re-dispatches the click with a one-shot marker so LiveView handles it as usual.
const confirmDialog = document.getElementById("canopy-confirm")
if (confirmDialog) {
  let pending = null
  const close = () => { pending = null; confirmDialog.close() }
  document.addEventListener("click", e => {
    const el = e.target.closest("[data-canopy-confirm]")
    if (!el || el.dataset.canopyConfirmed === "1") return
    e.preventDefault()
    e.stopImmediatePropagation()
    pending = el
    document.getElementById("canopy-confirm-title").textContent = el.dataset.canopyConfirmTitle || "Are you sure?"
    document.getElementById("canopy-confirm-message").textContent = el.dataset.canopyConfirm
    document.getElementById("canopy-confirm-ok").textContent = el.dataset.canopyConfirmLabel || "Confirm"
    confirmDialog.showModal()
  }, true)
  document.getElementById("canopy-confirm-cancel").addEventListener("click", close)
  confirmDialog.addEventListener("click", e => { if (e.target === confirmDialog) close() })
  confirmDialog.addEventListener("cancel", e => { e.preventDefault(); close() })
  document.getElementById("canopy-confirm-ok").addEventListener("click", () => {
    const el = pending
    close()
    if (!el) return
    el.dataset.canopyConfirmed = "1"
    el.click()
    delete el.dataset.canopyConfirmed
  })
}

// The command palette's shortcut: ⌘K on a Mac (Ctrl+K there is the text
// fields' kill-line, and the composer is a textarea), Ctrl+K elsewhere, where
// it would otherwise focus the browser's search. Ignored while another modal
// is open, and a no-op until the page's LiveView has mounted the hook.
const mac = /mac/i.test((navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "")
document.documentElement.dataset.platform = mac ? "mac" : "other"
document.addEventListener("keydown", e => {
  if (e.key !== "k" && e.key !== "K") return
  if (e.isComposing || e.repeat || e.altKey || e.shiftKey) return
  if (mac ? !e.metaKey || e.ctrlKey : !e.ctrlKey || e.metaKey) return
  const palette = document.getElementById("cmdk")
  if (!palette) return
  if (document.querySelector("dialog[open]:not(#cmdk-dialog), #dm-picker, #library-picker, #changes-modal, #model-picker, #setup-dialog")) return
  e.preventDefault()
  palette.dispatchEvent(new CustomEvent("cmdk:toggle"))
})

// Copy buttons: JS.dispatch("canopy:copy", to: "#element", detail: {button: id})
// copies the element's text; the button's [data-copy-label] says "Copied" for
// a moment.
window.addEventListener("canopy:copy", e => {
  const text = e.target.innerText || e.target.textContent || ""
  const button = e.detail && e.detail.button && document.getElementById(e.detail.button)
  copyText(text).then(() => {
    const label = button && button.querySelector("[data-copy-label]")
    if (!label) return
    if (!label.dataset.original) label.dataset.original = label.textContent
    label.textContent = "Copied"
    clearTimeout(label.copyTimer)
    label.copyTimer = setTimeout(() => { label.textContent = label.dataset.original }, 1500)
  }, () => {})
})

// The mobile drawer (rail + sidebar) closes when navigation lands somewhere.
window.addEventListener("phx:page-loading-stop", _info => {
  const drawer = document.getElementById("app-drawer")
  if (drawer) drawer.checked = false
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

