// Copies text to the clipboard. Plain http on a LAN (CANOPY_BIND) has no
// clipboard API, so a hidden textarea and execCommand stand in.
export default function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text)
  return new Promise((resolve, reject) => {
    const box = document.createElement("textarea")
    box.value = text
    box.setAttribute("readonly", "")
    box.style.position = "fixed"
    box.style.opacity = "0"
    document.body.appendChild(box)
    box.select()
    try { document.execCommand("copy") ? resolve() : reject() } catch (e) { reject(e) }
    box.remove()
  })
}
