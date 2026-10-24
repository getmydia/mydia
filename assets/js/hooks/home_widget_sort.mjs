// Drag-to-reorder for the visible rows in the Customize Home modal.
//
// SortableJS moves the row nodes itself, then the hook sends the whole new
// order in one reorder_home_widgets push. The list is not phx-update="ignore":
// the server re-renders the order the DOM already shows, and the keyed row ids
// let LiveView patch without undoing the drag. If the save fails the server
// keeps the old order and the patch puts the rows back.
//
// Arrow keys on a focused handle reuse move_home_widget. LiveView moves the
// row node during the patch, which drops focus, so updated() puts it back.

import Sortable from "sortablejs";

const HANDLE = "[data-drag-handle]";

export function keyDirection(event) {
  if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return null;
  if (event.key === "ArrowUp") return "up";
  if (event.key === "ArrowDown") return "down";
  return null;
}

export function orderedKeys(container) {
  return Array.from(container.querySelectorAll(":scope > [data-key]"), (row) => row.dataset.key);
}

const HomeWidgetSort = {
  mounted() {
    this.sortable = Sortable.create(this.el, {
      handle: HANDLE,
      draggable: "[data-key]",
      animation: 150,
      onEnd: (event) => {
        if (event.oldIndex === event.newIndex) return;
        this.pushEvent("reorder_home_widgets", { keys: orderedKeys(this.el) });
      },
    });

    this.onKeydown = (event) => {
      const handle = event.target.closest(HANDLE);
      if (!handle) return;
      const direction = keyDirection(event);
      if (!direction) return;
      event.preventDefault();
      const key = handle.closest("[data-key]").dataset.key;
      this.focusKey = key;
      this.pushEvent("move_home_widget", { key, direction });
    };
    this.el.addEventListener("keydown", this.onKeydown);
  },

  updated() {
    if (!this.focusKey) return;
    const row = this.el.querySelector(`[data-key="${CSS.escape(this.focusKey)}"]`);
    row?.querySelector(HANDLE)?.focus();
    this.focusKey = null;
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown);
    this.sortable?.destroy();
  },
};

export default HomeWidgetSort;
