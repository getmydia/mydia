# Player testing: scripted transports and the codegen gap

## Scripting a Mydia server in a test

A Mydia instance's requests all go through a `MydiaGqlTransport`, so a test
stands in for the server by handing a fake transport to `fakeMydiaClient`
(`test/core/sources/mydia/fake_mydia_client.dart`). There are two fakes.

**`ScriptedMydiaTransport`** (`test/test_utils/scripted_mydia_transport.dart`)
answers per request. It is the one to reach for in screen tests, where the
requests a screen sends are numerous and their order is not the point.

- **Script by operation.** The handler receives a `ScriptedRequest` with the
  operation name, variables, token and timeout, so branch on `request.operation`.
  It returns a data map, or throws by returning a `SourceException` or other
  `Exception`. `ScriptedMydiaTransport.operationOf` and `.of(operation)` read
  back what was sent.
- **Sequence with `.responses`.** `ScriptedMydiaTransport.responses([...])`
  answers in order and repeats the last entry once the list runs out. That
  repeat means a mis-scripted test does not necessarily go red, so use it only
  where a single operation is sent, and prefer the per-operation handler as soon
  as a screen sends a second one. Adding a query to a screen shifts every later
  index.
- **Gate with a future.** A handler may return a `Future`, so a test can hold a
  request open and release it when the scenario calls for it (a disposal while a
  request is in flight, a late answer after a seek).
- **Fail with `graphqlError`.** `graphqlError('message', data: {...})` is the
  `MydiaGraphqlError` a client raises for a server-side GraphQL error, with
  optional partial `data`. Use it for failure paths rather than a bare
  `Exception`, so the code under test sees the type it sees in production.

**`FakeMydiaTransport`** (`test/core/sources/mydia/fake_mydia_transport.dart`)
is handler-per-operation: `handlers['MovieDetail'] = (vars) => {...}`, with a
`calls` list, an `unreachable` switch, and `validTokens` so a token refresh can
be exercised (any other token answers unauthorized). An operation with no
handler answers a server error, which fails loudly rather than returning
somebody else's payload. Use it for client, source and service tests.

**Completeness.** A canned response must carry every field the query selects.
When a query gains a field, every hand-written response feeding that screen must
gain the key too, even as an explicit `null`, so the stub keeps matching what the
server sends. A stub that falls behind its query degrades the screen quietly and
the failure surfaces somewhere unrelated, often as a layout assertion far from
the stub. (The case below predates the removal of the GraphQL cache that
caused it, but the symptom is the one to watch for.) Observed 2026-08-13 extracting
`tvShowDetailQuery` into `player/lib/graphql/queries/show_detail.graphql` and
adding `watchStatus`: two tests in `show_detail_screen_test.dart` began failing
on layout (`play.bottom` was 410, asserted `< 380`) and on a `Bad state: No
element` inside `scrollUntilVisible`, and neither mentions watch state. The fix
was adding `'watchStatus': null` to the `TvShow` and `Season` maps.

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

A scripted transport compounds it: it answers whatever the test scripted without
ever checking the request document against the schema, so a test can exercise a
mutation the server would reject and still pass.

Put new player operations in `player/lib/graphql/**/*.graphql` and use the
generated `documentNodeMutationX` and `Variables$Mutation$X` rather than an inline
string. `player/test/graphql/schema_conformance_test.dart` parses every
document the player ships, inline strings included, and asserts each root field
exists in the schema, so a regression fails there. That guard is root-fields-only,
and codegen is still the real validator. `no_orphan_documents_test.dart` fails
on a document nothing sends.

## E2E harness layout

The E2E server runs the production image built from the root `Dockerfile`.
`scripts/e2e/server-entrypoint.sh` wraps the stock production entrypoint and,
once the server reports healthy, runs `scripts/e2e/seed.sh`, which seeds test
data through `su-exec mydia /app/bin/mydia rpc "..."`, using `rpc` rather than
`eval` for the same reason production access does. The test runner is the
toolbox image from `player/Dockerfile.test`, which installs Flutter from
`player/.fvmrc`.

Player E2E tests live in `player/integration_test/`, with streaming helpers in
`player/integration_test/helpers/streaming_helpers.dart`. The compose file is
`compose.player-e2e.yml`.

### A failure named `simple` is usually not from `simple`

CI runs every file through `all_tests.dart` in one isolate. The engine's frame
callbacks bind to the zone of the first test that schedules a frame, which is
`simple`. From then on, anything that runs from a frame callback reports against
`simple`: `debugPrint` output, and any error thrown after its own test finished.
The reporter shows these as `simple App boots with the native bridge initialized`
failing "after it had already completed", interleaved with progress lines from
whichever test is actually running. Read the stack trace, not the label. On
2026-09-16 that line was a `PlayerScreen` teardown inside `remote_control`.

To reproduce one file on its own, where attribution is exact:

```bash
./dev player e2e --target integration_test/remote_control_test.dart
```

The test container runs as root and bind-mounts the checkout, so a local run
leaves root-owned build output and generated files under `player/`, and the
next `./dev player setup` fails with `Permission denied` on
`.dart_tool/package_config.json`. Give them back without sudo:

```bash
docker run --rm -v "$PWD/player:/p" --entrypoint find \
  ghcr.io/getmydia/mydia/player-e2e-toolbox:master \
  /p -user root -exec chown -h "$(id -u):$(id -g)" {} +
```
