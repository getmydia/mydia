// A checkbox has no HTML attribute for the indeterminate state, only a DOM
// property. The server renders `data-state="all|none|partial"` and this hook
// mirrors "partial" onto the property after every patch.
const IndeterminateCheckbox = {
  mounted() {
    this.sync();
  },
  updated() {
    this.sync();
  },
  sync() {
    this.el.indeterminate = this.el.dataset.state === "partial";
  },
};

export default IndeterminateCheckbox;
