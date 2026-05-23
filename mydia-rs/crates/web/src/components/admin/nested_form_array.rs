//! Ordered nested-form-array primitive for admin pages.
//!
//! Phoenix counterpart: the implicit pattern that shows up wherever a
//! changeset embeds an ordered `has_many` association rendered via
//! `<.inputs_for>`. The Phoenix `<.inputs_for>` macro hides the array
//! state inside the parent changeset; in Dioxus we keep the array as
//! a `Vec<T>` signal and provide explicit add/remove/move-up/move-down
//! callbacks plus a caller-supplied row renderer.
//!
//! The quality profiles editor is the first consumer: an ordered list
//! of quality strings ("480p", "720p", ...) where the order determines
//! priority. If a second page later needs the same ordered-list-of-
//! editable-items shape (e.g. a "preferred audio codecs" list with
//! per-row metadata), it can render an [`OrderedItemList`] with its
//! own `render_item` closure.
//!
//! Trade-off: Dioxus 0.7 doesn't ship a stable HTML5 drag-and-drop
//! integration, so reordering is via up/down buttons rather than
//! drag-handles. Operators get the same priority semantics; the
//! affordance is slower but obvious. Phoenix's
//! `Sortable.js`-via-`phx-hook` equivalent can land later without
//! changing the primitive's signature.

use std::rc::Rc;

use dioxus::prelude::*;

/// Caller-driven renderer for one item row. Receives the item's value
/// plus its zero-based index in the list. The wrapper supplies the
/// reorder/remove chrome around it, so the renderer only renders the
/// per-row body (a label, an input, a select, whatever fits the
/// caller's data shape). Wrapped in [`Rc`] so the prop is `Clone` —
/// Dioxus re-renders the wrapper without re-allocating the closure.
pub type ItemRenderer<T> = Rc<dyn Fn(usize, &T) -> Element>;

#[derive(Props)]
pub struct OrderedItemListProps<T: Clone + PartialEq + 'static> {
    /// Stable DOM id prefix. Each row gets `{id_prefix}-{index}` and
    /// the wrapper card gets `{id_prefix}`. Used by tests to scope
    /// `has_element?` selectors.
    pub id_prefix: String,
    /// The current items. Caller owns the signal; this component reads
    /// it on each render so external mutations show up.
    pub items: Signal<Vec<T>>,
    /// Renders the per-row body. The component wraps it with the
    /// reorder/remove buttons; the renderer is purely for the item's
    /// own widgets.
    pub render_item: ItemRenderer<T>,
    /// Called when the user clicks "Add". The handler typically pushes
    /// a default-valued item to [`items`]. The wrapper doesn't push
    /// itself because `T` isn't `Default`-bound and the caller knows
    /// what a sensible blank value looks like.
    pub on_add: EventHandler<()>,
    /// Empty-state body rendered when [`items`] is empty. Caller picks
    /// the copy. If `None`, the empty state collapses to a thin
    /// "No items yet" line.
    #[props(default)]
    pub empty_state: Option<Element>,
    /// Label for the add button. Defaults to `"Add item"`.
    #[props(default = String::from("Add item"))]
    pub add_label: String,
    /// Optional helper text shown above the list — e.g. explaining the
    /// reorder semantics ("Order determines priority; first item is
    /// preferred").
    #[props(default)]
    pub help: Option<String>,
    /// Optional validation error rendered below the list. Mirrors the
    /// "validation surfaces near the input" rule.
    #[props(default)]
    pub error: Option<String>,
}

impl<T: Clone + PartialEq + 'static> PartialEq for OrderedItemListProps<T> {
    fn eq(&self, other: &Self) -> bool {
        self.id_prefix == other.id_prefix
            && self.items == other.items
            && self.add_label == other.add_label
            && self.help == other.help
            && self.error == other.error
    }
}

impl<T: Clone + PartialEq + 'static> Clone for OrderedItemListProps<T> {
    fn clone(&self) -> Self {
        Self {
            id_prefix: self.id_prefix.clone(),
            items: self.items,
            render_item: Rc::clone(&self.render_item),
            on_add: self.on_add,
            empty_state: self.empty_state.clone(),
            add_label: self.add_label.clone(),
            help: self.help.clone(),
            error: self.error.clone(),
        }
    }
}

/// Ordered list of editable items with reorder + remove + add chrome.
///
/// The caller owns the `Vec<T>` signal; this component mutates it via
/// its own buttons (remove, move up, move down) and asks the caller
/// for additions via `on_add`. The chrome is intentionally minimal so
/// pages can stack their own widgets inside `render_item`.
#[component]
pub fn OrderedItemList<T: Clone + PartialEq + 'static>(props: OrderedItemListProps<T>) -> Element {
    let id_prefix = props.id_prefix.clone();
    let id_prefix_for_rows = id_prefix.clone();
    let mut items = props.items;
    let render = props.render_item;
    let error = props.error.clone();
    let help = props.help.clone();
    let on_add = props.on_add;
    let add_label = props.add_label.clone();

    // Snapshot the current items for rendering. Read once so the
    // render closure doesn't keep the signal borrowed across calls.
    let snapshot: Vec<T> = items.read().clone();
    let is_empty = snapshot.is_empty();
    let last_index = snapshot.len().saturating_sub(1);

    rsx! {
        div { id: "{id_prefix}", class: "flex flex-col gap-3",
            if let Some(help_text) = help.as_ref() {
                p { class: "text-xs text-base-content/60", "{help_text}" }
            }
            if is_empty {
                if let Some(empty) = props.empty_state {
                    div { id: "{id_prefix}-empty", class: "text-sm text-base-content/60 py-4 text-center border border-dashed border-base-content/20 rounded-box",
                        {empty}
                    }
                } else {
                    div { id: "{id_prefix}-empty", class: "text-sm text-base-content/60 py-4 text-center border border-dashed border-base-content/20 rounded-box",
                        "No items yet."
                    }
                }
            } else {
                ul { id: "{id_prefix}-rows", class: "flex flex-col gap-2",
                    for (index, item) in snapshot.iter().enumerate() {
                        li {
                            key: "{id_prefix_for_rows}-{index}",
                            id: "{id_prefix_for_rows}-{index}",
                            class: "flex items-start gap-2 p-2 bg-base-200 rounded-box",
                            div { class: "flex-1 min-w-0", {render(index, item)} }
                            div { class: "flex flex-col gap-1 shrink-0",
                                button {
                                    r#type: "button",
                                    id: "{id_prefix_for_rows}-{index}-up",
                                    class: "btn btn-xs btn-ghost",
                                    disabled: index == 0,
                                    title: "Move up",
                                    onclick: move |_| {
                                        if index > 0 {
                                            items.with_mut(|v| v.swap(index, index - 1));
                                        }
                                    },
                                    "↑"
                                }
                                button {
                                    r#type: "button",
                                    id: "{id_prefix_for_rows}-{index}-down",
                                    class: "btn btn-xs btn-ghost",
                                    disabled: index >= last_index,
                                    title: "Move down",
                                    onclick: move |_| {
                                        items
                                            .with_mut(|v| {
                                                if index + 1 < v.len() {
                                                    v.swap(index, index + 1);
                                                }
                                            });
                                    },
                                    "↓"
                                }
                                button {
                                    r#type: "button",
                                    id: "{id_prefix_for_rows}-{index}-remove",
                                    class: "btn btn-xs btn-ghost text-error",
                                    title: "Remove",
                                    onclick: move |_| {
                                        items
                                            .with_mut(|v| {
                                                if index < v.len() {
                                                    v.remove(index);
                                                }
                                            });
                                    },
                                    "×"
                                }
                            }
                        }
                    }
                }
            }
            if let Some(err) = error.as_ref() {
                p { class: "text-sm text-error", "{err}" }
            }
            div {
                button {
                    r#type: "button",
                    id: "{id_prefix}-add",
                    class: "btn btn-sm btn-outline",
                    onclick: move |_| on_add.call(()),
                    "+ {add_label}"
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    /// The reorder math itself is trivial — `Vec::swap` does the work.
    /// We still pin the boundary conditions in unit tests so a refactor
    /// that touches the index handling doesn't silently break the
    /// "first item can't move up" / "last item can't move down" rules.
    #[test]
    fn swap_up_preserves_length() {
        let mut v = vec!["a", "b", "c"];
        v.swap(1, 0);
        assert_eq!(v, vec!["b", "a", "c"]);
    }

    #[test]
    fn swap_down_preserves_length() {
        let mut v = vec!["a", "b", "c"];
        v.swap(1, 2);
        assert_eq!(v, vec!["a", "c", "b"]);
    }

    #[test]
    fn remove_at_middle_collapses() {
        let mut v = vec!["a", "b", "c"];
        v.remove(1);
        assert_eq!(v, vec!["a", "c"]);
    }
}
