// Keeps the sidebar where you left it across live navigation. Each navigate
// re-renders the sidebar, which would reset its scroll to the top; the last
// position is kept per tab and restored on every mount.
const KEY = "canopy:sidebar-scroll"

const SidebarScroll = {
  mounted() {
    let stored = null
    try { stored = sessionStorage.getItem(KEY) } catch (_) {}
    if (stored !== null) this.el.scrollTop = parseInt(stored, 10) || 0
    this.el.addEventListener("scroll", () => {
      try { sessionStorage.setItem(KEY, String(this.el.scrollTop)) } catch (_) {}
    }, {passive: true})
  },
}

export default SidebarScroll
