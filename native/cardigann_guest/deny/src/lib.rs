//! Trapping stand-ins for every wasi:http and wasi:sockets interface the
//! Cardigann guest imports.
//!
//! The .NET runtime inside the guest links these interfaces but the engine never
//! calls them: its only egress is `mydia:cardigann/host.http-request`. build.sh
//! composes this component under the guest, so the final component has no
//! wasi:http or wasi:sockets import and instantiates under `allow_http: false`.
//! If a stand-in ever runs, the guest traps (`unreachable`) instead of reaching
//! the network.
//!
//! `gen/stubs.rs` is `wit-bindgen rust --stubs --generate-all` output (see
//! build.sh): the bindings plus an `impl` of every exported trait on `Stub`, so
//! it tracks the WIT exactly and ends with `export!(Stub)`. Every body is
//! `unreachable!()`.
#![allow(clippy::all, warnings)]

include!("../gen/stubs.rs");

