// Whether the archive that is about to be confirmed came from the keyboard
// (a menu item chosen with Enter, the palette). The Undo toast moves focus to
// its button only then; a mouse archive leaves focus where it was.
let keyboardAt = 0

export function markKeyboardArchive() { keyboardAt = Date.now() }

export function takeKeyboardArchive() {
  const recent = Date.now() - keyboardAt < 2000
  keyboardAt = 0
  return recent
}
