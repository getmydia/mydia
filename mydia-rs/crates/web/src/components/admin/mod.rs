//! Admin-domain shared components.
//!
//! Phoenix counterpart: `lib/mydia_web/components/admin_components.ex`
//! plus the per-page `live/admin_*_live/components.ex` files. These
//! are the chrome bits the operational admin pages reuse — a page
//! header with optional actions, a filter pill bar, an empty-state
//! card, and a status-pill badge keyed on a Phoenix-style status
//! string ("pending", "completed", "failed", ...).
//!
//! Page-private components stay alongside the page file (e.g., the
//! user-create modal lives in `pages/admin/users.rs`) — only patterns
//! that recur across 2+ admin pages graduate here.
//!
//! U28 follow-up cohort adds [`config_form`] — the
//! `<.section>`-style card + labelled row primitives the
//! configuration-heavy admin pages (system, settings, download
//! clients, indexers, media servers, remote access, import lists,
//! release blacklist) share. Quality profiles uses the same
//! primitive at the outer level even though its inner "form driving
//! forms" is page-private.
//!
//! The quality-profiles CRUD follow-up adds [`nested_form_array`] —
//! a minimal "ordered list of editable items" primitive (add /
//! remove / move-up / move-down + caller-supplied row renderer).
//! Quality profiles is the first consumer; the shape is generic
//! enough to fit any future page that wants the same priority-
//! ordered editable list pattern.

mod config_form;
mod filter_bar;
mod nested_form_array;
mod page_header;
mod status_pill;

pub use config_form::{
    ConfigRow, ConfigRowProps, ConfigSection, ConfigSectionProps, ConfigSource, SourcePill,
    SourcePillProps, StatRow, StatRowProps,
};
pub use filter_bar::{FilterBar, FilterOption};
pub use nested_form_array::{ItemRenderer, OrderedItemList, OrderedItemListProps};
pub use page_header::{AdminPageHeader, AdminPageHeaderProps};
pub use status_pill::{status_pill_class, StatusPill};
