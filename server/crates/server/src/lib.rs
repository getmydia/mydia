//! Library face of the server crate, so integration tests can build the
//! router without starting a listener. The binary in main.rs uses this same
//! library rather than declaring its own copy of the modules.

pub mod media;
pub mod router;
pub mod scanner;
pub mod test_support;

pub use router::AppState;
