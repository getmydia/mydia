//! Discovery resolvers — port of
//! `lib/mydia_web/schema/resolvers/discovery_resolver.ex`. Lands in
//! U10.b. The placeholder struct keeps the schema buildable so U10.a
//! can ship and run integration tests without waiting on the
//! Playback context port.

#[derive(Default)]
pub struct DiscoveryQueries;

#[async_graphql::Object]
impl DiscoveryQueries {
    /// Sentinel field — keeps the resolver Object non-empty while
    /// the real fields (`continueWatching`, `recentlyAdded`,
    /// `upNext`, `favorites`, `unwatched`) come online.
    async fn discovery_pending(&self) -> &'static str {
        "U10.b — discovery resolvers pending"
    }
}
