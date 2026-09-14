// Browser-side marks for library selection.
//
// A streamed media card only re-renders on an explicit stream insert, so a
// server handler that only updates `selected_ids` never reaches a card that is
// already on screen. Every selection change is therefore mirrored here onto
// the card's `data-selected` attribute, which draws the outline in app.css,
// and its hidden `input.select-checkbox`, which flips the check-mark swap.

export const ITEM_SELECTOR = ".media-grid-item, .media-list-item";

export function setItemSelected(item, selected) {
  item.dataset.selected = String(selected);

  const checkbox = item.querySelector("input.select-checkbox");
  if (checkbox) checkbox.checked = selected;
}

export function setAllSelected(container, selected) {
  container.querySelectorAll(ITEM_SELECTOR).forEach((item) => setItemSelected(item, selected));
}

export function toggleAllSelected(container) {
  const items = [...container.querySelectorAll(ITEM_SELECTOR)];
  const allSelected = items.every((item) => item.dataset.selected === "true");

  items.forEach((item) => setItemSelected(item, !allSelected));
}

// Clears every mark when the server turns selection mode off. Esc, the header
// Select button and the bulk actions end selection on the server alone, and a
// card keeps whatever `data-selected` the browser last gave it (app.js's
// onBeforeElUpdated even carries "true" across patches), so without this the
// outlines outlive the selection.
//
// The hook sits on its own element, which mirrors the server's selection mode
// in `data-selecting` and names the card container in `data-container`.
//
// Only the transition clears. The hover checkbox marks its card before the
// server's patch turns selection mode on, so clearing on every update outside
// selection mode would wipe that mark if an unrelated patch landed first.
export const MediaSelection = {
  mounted() {
    this.wasSelecting = isSelecting(this.el);
  },

  updated() {
    const selecting = isSelecting(this.el);

    if (this.wasSelecting && !selecting) {
      const container = document.getElementById(this.el.dataset.container);
      if (container) setAllSelected(container, false);
    }

    this.wasSelecting = selecting;
  },
};

function isSelecting(el) {
  return el.dataset.selecting === "true";
}
