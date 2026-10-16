// A plain textarea that takes pasted files: they go to the upload config
// named in data-upload (the Start page's brief). Text pastes are left to the
// browser. The channel composer does the same inside its own hook.
import {pastedFiles} from "../pasted_files"

const PasteUpload = {
  mounted() {
    this.el.addEventListener("paste", e => {
      const files = pastedFiles(e)
      if (files.length === 0) return
      e.preventDefault()
      this.upload(this.el.dataset.upload, files)
    })
  },
}

export default PasteUpload
