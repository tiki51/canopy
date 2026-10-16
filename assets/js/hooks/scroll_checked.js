// A scrolling list of radios: on mount, scroll the checked one's row into
// view, so a preselection below the fold shows. A user's own pick is already
// in view, so updates leave the scroll alone.
const ScrollChecked = {
  mounted() {
    const checked = this.el.querySelector("input:checked")
    if (checked) (checked.closest("li") || checked).scrollIntoView({block: "nearest"})
  },
}

export default ScrollChecked
