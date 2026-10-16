// The files in a paste event, for an upload config. A screenshot from the
// clipboard arrives as "image.png"; generic names become
// paste-YYYYMMDD-HHMMSS.png so several pastes stay apart. An empty list
// means a text paste, which is left to the browser.
export function pastedFiles(e) {
  const files = Array.from((e.clipboardData && e.clipboardData.files) || [])
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "").replace("T", "-")
  return files.map((file, i) => {
    const generic = /^(image|file|blob)(\.\w+)?$/i.test(file.name) || file.name === ""
    if (!generic) return file
    const ext = (file.name.match(/\.\w+$/) || [file.type ? "." + file.type.split("/")[1] : ""])[0]
    return new File([file], `paste-${stamp}${files.length > 1 ? "-" + (i + 1) : ""}${ext}`, {type: file.type})
  })
}
