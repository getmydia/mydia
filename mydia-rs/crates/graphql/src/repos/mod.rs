//! DB-layer query helpers — the Rust counterpart of Phoenix's
//! `Mydia.Media`, `Mydia.Settings`, `Mydia.Library`, `Mydia.Playback`
//! context modules. One module per Phoenix context, each exposing the
//! slice of functions the GraphQL resolvers in U10–U14 call into.
//!
//! These functions take a `&Db` handle and dispatch SQL through the
//! [`mydia_rs_db::dialect`] helpers when the query is dialect-
//! divergent. Most browse queries are portable enough to use plain
//! string SQL with `?` parameter binding, which sqlx rewrites to the
//! right placeholder syntax per pool.

pub mod media;
pub mod settings;
