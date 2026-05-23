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

mod filter_bar;
mod page_header;
mod status_pill;

pub use filter_bar::{FilterBar, FilterOption};
pub use page_header::{AdminPageHeader, AdminPageHeaderProps};
pub use status_pill::{status_pill_class, StatusPill};
