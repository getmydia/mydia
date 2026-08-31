# The GraphQL contract

Two servers implement the same player-facing GraphQL contract: this Elixir app and
the Rust `mydia-api` crate under `server/crates/api/`. The Flutter player talks to
both, so the schema is a shared contract rather than one app's API.

## Layout

The schema lives in `lib/mydia_web/schema/`, split across `query_types`,
`mutation_types`, `common_types` and `media_types`, with resolvers in
`lib/mydia_web/schema/resolvers/`. Absinthe auto-converts snake_case fields to
camelCase in responses, so a Rust or Dart consumer sees camelCase while the Elixir
source reads snake_case.

The checked-in contract the player is built against is
`player/lib/graphql/schema.graphql`, a symlink to the generated
`priv/graphql/schema.graphql`.

## Shapes worth knowing before writing a query

- Movies uses connection, edges and node pagination:
  `movies { edges { node { id title files { id } } } }`
- `startStreamingSession` returns `streaming_session_result` carrying `session_id`
  and `duration`. There is no `hlsUrl`; the client builds the playlist URL itself.
- `endStreamingSession` returns a raw `:boolean`, not a result object.

Key context module signatures: `Mydia.Media.create_media_item/2` (attrs, then an
opts keyword list carrying `skip_episode_refresh`),
`Mydia.Library.create_media_file/1` (attrs map),
`Mydia.Settings.create_library_path/1` (attrs: path, type), and
`Mydia.RemoteAccess.p2p_status/0`, which returns `{:ok, %P2p.Server.Status{}}`.

## The SDL parity gate couples this schema to the Rust crate

`server/crates/api/tests/sdl_parity.rs` asserts the Rust server's schema is
structurally identical to `player/lib/graphql/schema.graphql`. It canonicalizes
both and diffs line by line, so any field present in one and not the other fails
the `Format, lint and test` CI job.

The gate is load-bearing. Its own doc comment explains why: GraphQL treats an
unknown field as a document-level validation error, so one missing field fails the
entire query it appears in, not just that field. Parity is what keeps the player
working against either backend.

Any PR adding or changing an Elixir GraphQL field must, in the same PR:

1. Run `./dev mix schema.export` and commit `priv/graphql/schema.graphql`. Note
   that `MydiaWeb.SchemaSdlTest` lives at `test/mydia_web/schema_sdl_test.exs`,
   beside `test/mydia_web/schema/` rather than inside it, so running that
   directory silently skips it.
2. Add the field to `server/crates/api/`. A new or changed field on a type means
   editing the `#[derive(SimpleObject)]` struct in
   `server/crates/api/src/types/*.rs`, where `Option<String>` maps to a nullable
   `String`. A deprecation means `#[graphql(deprecation = "...")]` on the resolver
   in `server/crates/api/src/query.rs`, with a reason string matching Absinthe's
   `deprecate(...)` text exactly.

Implementing the Rust side is usually cheap, because parity is structural only.
The Rust resolvers are schema-only stubs returning `Ok(None)`, and the SDL-fragment
test harness uses `std::future::pending().await` rather than struct literals, so
adding a field breaks no construction sites. A field outside that product's scope
can be structurally present and honest at runtime: `subtitleSearch` returns empty
results plus a status string explaining the backend does not do that,
`downloadSubtitle` returns the existing `not_implemented` helper from `context.rs`
when the return type is non-null and cannot answer null, and genuinely in-scope
fields like `deliverable` get real implementations. Follow the convention in
`query.rs` and `mutation.rs`, citing the Elixir source file in a doc comment.

Verify locally rather than paying for a CI round trip:

```
devenv shell -- bash -c "cd server && cargo test -p mydia-api --test sdl_parity"
```

Caught 2026-08-12 on PR #429 (merged On Deck rail), which added `state` to
`ContinueWatchingItem` and deprecated `upNext`, and again the same day adding
`subtitleSearch`, `downloadSubtitle` and `SubtitleTrack.content`/`deliverable`.
Nothing in the Elixir code, the player or the SDL references the Rust crate, so
this is invisible unless you know to look, and the failing CI job is named
"Format, lint and test", which gives no hint that GraphQL is involved.

When piping cargo through `tail`, the pipeline's exit code is `tail`'s and
truncation hides earlier binaries' results. Grep for `test result` instead.

## Media byte URLs use two auth transports

`player/lib/presentation/screens/player/player_screen.dart:893-916` picks between
two auth transports for media byte requests, and any server serving those bytes
has to accept both.

In password mode there is no query token at all; the player sets
`httpHeaders = {'Authorization': 'Bearer $token'}` with its regular access token.
In claim-code mode it appends `?token=<media token>` to the URL and sets no
header. See also `player/lib/core/player/streaming_strategy.dart:69` and
`player/lib/core/auth/media_token_service.dart:136`.

Media tokens exist only for claim-code pairing. A server accepting only media
tokens on its byte endpoints breaks every ordinary local install, and one
accepting only headers breaks every paired one. `MydiaWeb.Plugs.MediaAuth`
(`media_auth.ex:6-7`) accepts either token from either transport.

Stream URLs are served under `/api/v1` while subtitle URLs are under
`/api/player/v1`. Different router scopes, easy to get wrong.
