# Player testing: StubLink and the codegen gap

## Three ways a StubLink stub silently mis-scripts a screen test

`player_screen_test_harness.dart`'s `StubLink` fails silently in three
independent ways. All surface as unrelated assertions breaking, never as a clear
stub error.

**Ordering.** `responses` is index-based and repeats its last entry. Adding a new
query to a screen shifts every subsequent index, so existing tests start answering
the wrong operation, and because the last entry repeats, a mis-scripted test does
not necessarily go red. It can keep passing while asserting against a response
meant for a different query. Measured 2026-08-03 when a `MovieSegments` query was
added to `PlayerScreen`: seven tests affected, three failed outright, and four
kept passing while silently mis-scripted. When adding a query to a player screen,
re-check every `StubLink.responses` script for that screen rather than only fixing
the tests that go red, and prefer the named per-operation helpers over raw
positional lists where they exist.

**Completeness.** A stub must carry every field the query selects. When a query
gains a field, every hand-written response feeding that screen must gain the key
too, even as an explicit `null`. Omitting it does not raise: graphql_flutter's
normalized cache treats the response as incomplete and hands the widget partial
data, so the screen renders degraded and the failure surfaces as unrelated layout
assertions elsewhere. Observed 2026-08-13 extracting `tvShowDetailQuery` into
`player/lib/graphql/queries/show_detail.graphql` and adding `watchStatus`. Two
pre-existing tests in `show_detail_screen_test.dart` began failing, "hero play
control lives in the hero, not the body" (`play.bottom` was 410, asserted `< 380`)
and "tapping a rail card carries the viewport back to the hero" (`Bad state: No
element` inside `scrollUntilVisible`). Neither test mentions watch state. The fix
was adding `'watchStatus': null` to the `TvShow` and `Season` maps.

**Routing.** `request.operation.operationName` is `null`, so never branch a
handler on it. A `StubLink` that must answer more than one operation, a screen
query plus a mutation say, cannot discriminate on the operation name, so every
comparison falls to the `else` branch and one operation is answered with the
other's payload. That surfaces as `OperationException(PartialDataException)` on
the success path and, worse, as vacuously passing failure-path tests: a test
asserting `throwsA(isA<OperationException>())` passes because of the misrouting
rather than the failure it meant to script. Measured 2026-08-19 adding
`removeFromContinueWatching`, where four success tests failed and two failure
tests passed for the wrong reason. Discriminate on `request.variables` keys
instead (the mutation's `mediaItemId` versus the home query's
`continueWatchingLimit`), which is stable and explicit.

The first bites when a screen issues an extra query, the second when an existing
query grows, and the third the moment one stub has to serve two operations.

When diagnosing this class of failure, bisect by component rather than by reading.
For the completeness case the suspected change was a season-chip badge, and
disabling the badge changed nothing. Restoring the old inline query while keeping
every other change is what isolated it to the query document. Only then does
looking at the stub pay off.

An agent once reported both failures as "pre-existing, not from this task". They
were not; both passed at `HEAD~1`. Verify such a claim by checking out the parent
commit's `player/` and re-running.

## Inline Dart GraphQL strings skip schema validation

graphql_codegen validates player documents against
`player/lib/graphql/schema.graphql` (a symlink to `priv/graphql/schema.graphql`),
but only documents living in `.graphql` files. Operations written as inline Dart
string literals (`const String fooQuery = r'''query Foo { ... }'''`) are invisible
to it and get zero schema checking.

This is not theoretical. `toggleShowFavorite(showId:)` and
`toggleMovieFavorite(movieId:)` were inline strings naming a mutation the server
never had; the real one has always been `toggleFavorite(mediaItemId:)`. Player
favoriting was dead for movies and shows for the entire life of the Flutter
client, fixed in PR #396.

`StubLink` compounds it, returning canned responses by index without ever checking
the request document against the schema, so a test can exercise a mutation the
server would reject and still pass.

Put new player operations in `player/lib/graphql/**/*.graphql` and use the
generated `documentNodeMutationX` and `Variables$Mutation$X` rather than an inline
string. `player/test/core/graphql/schema_conformance_test.dart` now parses every
document the player ships, inline strings included, and asserts each root field
exists in the schema, so a regression fails there. That guard is root-fields-only,
and codegen is still the real validator.

## E2E harness layout

The E2E server is built via `Dockerfile.e2e`, on an `erlang:27-alpine` runtime
with ffmpeg added. The entrypoint script seeds test data through
`su-exec mydia /app/bin/mydia rpc "..."`, using `rpc` rather than `eval` for the
same reason production access does.

Player E2E tests live in `player/integration_test/`, with streaming helpers in
`player/integration_test/helpers/streaming_helpers.dart`. The compose file is
`compose.player-e2e.yml`.
