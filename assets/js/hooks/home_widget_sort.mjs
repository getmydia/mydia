// Drag-to-reorder for the visible rows in the Customize Home modal.
//
// SortableJS moves the row nodes itself, then the hook sends the whole new
// order in one reorder_home_widgets push. Every reorder and move event replies
// with the order the server actually saved. When the DOM differs from it (a
// failed save, a no-op, a sanitized payload) the hook re-sorts the rows to
// match, because LiveView sends no diff when the assigns did not change.
//
// Arrow keys on a focused handle reuse move_home_widget. The reply callback
// runs after LiveView has applied the patch from the same event, so it is the
// point where the moved row's handle gets its focus back.

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

export function sameOrder(a, b) {
  return a.length === b.length && a.every((key, index) => key === b[index]);
}

// Moving the row node drops focus to the body. Anything else focused by the
// time the reply lands is where the user went, so it is left alone.
export function focusLeftAlone(active, handle) {
  return !active || active === handle || active === active.ownerDocument?.body;
}

const HomeWidgetSort = {
  mounted() {
    this.sortable = Sortable.create(this.el, {
      handle: HANDLE,
      draggable: "[data-key]",
      dataIdAttr: "data-key",
      animation: 150,
      onEnd: (event) => {
        if (event.oldIndex === event.newIndex) return;
        this.pushEvent("reorder_home_widgets", { keys: orderedKeys(this.el) }, (reply) =>
          this.syncOrder(reply),
        );
      },
    });

    this.onKeydown = (event) => {
      const handle = event.target.closest(HANDLE);
      if (!handle) return;
      const direction = keyDirection(event);
      if (!direction) return;
      event.preventDefault();
      const key = handle.closest("[data-key]").dataset.key;
      this.pushEvent("move_home_widget", { key, direction }, (reply) => {
        this.syncOrder(reply);
        if (focusLeftAlone(document.activeElement, handle)) this.focusHandle(key);
      });
    };
    this.el.addEventListener("keydown", this.onKeydown);
  },

  syncOrder(reply) {
    const keys = reply && reply.keys;
    if (!Array.isArray(keys) || sameOrder(orderedKeys(this.el), keys)) return;
    this.sortable.sort(keys, false);
  },

  focusHandle(key) {
    const row = this.el.querySelector(`:scope > [data-key="${CSS.escape(key)}"]`);
    row?.querySelector(HANDLE)?.focus();
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown);
    this.sortable?.destroy();
  },
};

export default HomeWidgetSort;
