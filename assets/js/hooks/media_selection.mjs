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
