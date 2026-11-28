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

## Tests share an isolate in CI

CI runs the VM suite as one bundle (see `workflow.md`), so a file inherits
whatever global state earlier files left behind. Three helpers in
`test/test_utils/` close the leaks that bundle exposed. Read each one's dartdoc
before using it.

- **`useRealHttp()`** (`real_http.dart`): call first in `main()` of any file that
  talks to a real local server. flutter_test's binding mocks `HttpOverrides.global`
  to answer 400, and a bundled run has always initialised it already.
- **`noHiveOverrides`** (`no_downloads.dart`): add to the container of any test
  that removes an account, so it never opens Hive. `noCollectionSyncOverride` is
  the collection-sync half of it; if your container already overrides
  `collectionSyncBoxProvider`, use `noDownloadsOverride` instead, because
  Riverpod rejects duplicate overrides.
- **`useInMemorySubtitlePrefs()`** (`in_memory_subtitle_prefs.dart`): call in
  `main()` of any file that mounts `SubtitleTrackSelectorSheet`, so the language
  prefs box is opened in memory and never touches disk.

## E2E harness layout

The player E2E is the `player-e2e` NixOS VM test (`nix/tests/player-e2e.nix`),
which `Test / Player E2E` in CI aggregates. It boots three VMs with no
internet: a metadata-relay, a server running the NixOS module on the Nix
package, and a client. Once the server reports healthy, a oneshot unit runs
`scripts/e2e/seed.sh`, which seeds test data through `bin/mydia rpc "..."`
(wrapped as `mydia-e2e-cli`), using `rpc` rather than `eval` for the same
reason production access does. The client runs `scripts/e2e/run-tests.sh` on
a copy of `player-codegen` with the crane-built p2p library, under Xvfb, with
the same Nix Flutter as the other player checks. The player reaches the server
over iroh directly on the VM network.

Run it locally (needs KVM; the VM run takes about three minutes once its
inputs are built):

```bash
nix build .#checks.x86_64-linux.player-e2e -L   # or: ./dev player e2e
```

On failure the build log carries the relay, server and seed journals and the
client's warnings; on success they are in the result's output (`./result` for
the `nix build` above, `./result-player-e2e` for `./dev player e2e`):
`player-e2e.log`, `mydia.log` and `metadata-relay.log`.

Player E2E tests live in `player/integration_test/`, with streaming helpers in
`player/integration_test/helpers/streaming_helpers.dart`.

### The playback E2E

`player/integration_test/playback_test.dart` plays real video in the E2E
VM. It is registered in `all_tests.dart` as the `playback` group and mounts
the real `PlayerScreen` on a real media_kit `Player`, then reads mpv's own
properties. It does not use the server's seeded movie: `scripts/e2e/run-tests.sh`
writes two clips with ffmpeg on the client VM (a 10 s 1280x720 `testsrc2` mp4
and the same video with one English SRT cue muxed in) and passes their
directory as `--dart-define=MYDIA_E2E_CLIPS`. The rig that does the mounting
is `integration_test/helpers/playback_rig.dart`. With no define the file
registers one skipped test; with the define and a clip missing it fails naming
the path.

The group has seven tests: a clip decodes and advances, the video output does
not hit the EGL display failure, a text subtitle draws in `kAppFontFamily`,
the fullscreen button enters and leaves fullscreen, closing mid-playback
disposes the player, closing right after opening leaves the app responsive,
and the stats sampler reports the render path.

**What the render assertion does not prove.** A published `hw` passes the
test outright, since only the patched display lookup can get there. Under
llvmpipe in the VM, today, the hardware path is unreachable: the patched video
output gets past the display check, fails `eglMakeCurrent` on its surfaceless
context and publishes `sw`, as the unpatched one would. On that path the test
asserts that media_kit never prints `EGL display or context is invalid` on
stderr (the rig captures the process's native stderr for this), and that the
output printed something there at all. Its success lines go to stdout, so
that second check is skipped when the path is `hw`. It catches the
regression that cost the player its hardware rendering once. It does not show
that frames render on the GPU, and a later break inside the hardware path
would pass.

Three things about the VM setup are not obvious:

- Fullscreen needs a window manager, so `run-tests.sh` starts `openbox` inside
  `xvfb-run`, on a 1920x1080 screen. Without one the fullscreen request goes
  unanswered.
- Every pump goes through `pumpBounded`. A flutter_test pump can hang forever
  when test code resumed by a microtask lands between a frame's `beginFrame`
  and `drawFrame`: the skipped frame leaves the scheduler believing one is
  still scheduled and none is ever drawn. `pumpBounded` runs each pump from a
  timer turn and fails with the scheduler's state after 10 s. Use it, and
  `waitFor`, for any pump in a test that plays video; a bare `tester.pump` can
  freeze the run.
- A frozen GTK thread stops Dart timers too, so no in-test timeout fires.
  `run-tests.sh` runs a watchdog: after 600 s it prints the app's native stacks
  with gdb and kills `bundle/mydia-player`, which fails the run with something
  to read.

**The count guard.** A skipped test, or one that returns before asserting,
still leaves `flutter test` at exit 0. After the suite, `run-tests.sh` calls
`scripts/ci/assert-test-count.sh` on the run's JSON report and fails unless at
least `PLAYBACK_MIN_PASSED` tests whose names start with `playback ` passed.
Adding a playback test means raising that constant at the top of
`run-tests.sh` in the same change; removing one means lowering it.
`scripts/ci/assert-test-count-test.sh` tests the guard itself and runs in
`Check / Repo Contracts`.

**Running only the playback file.** `E2E_TEST_TARGET=integration_test/playback_test.dart`
runs only that file through `run-tests.sh`, and so does plain
`flutter test integration_test/playback_test.dart -d linux
--dart-define=MYDIA_E2E_CLIPS=<dir>` with clips you generated yourself. Outside
`all_tests.dart` the tests have no `playback` group in front of their names, so
the guard's `playback ` prefix matches none of them and it fails with zero
passed. That is expected for a single-file run: read the test results, not the
guard.

### A failure named `simple` is usually not from `simple`

CI runs every file through `all_tests.dart` in one isolate. The engine's frame
callbacks bind to the zone of the first test that schedules a frame, which is
`simple`. From then on, anything that runs from a frame callback reports against
`simple`: `debugPrint` output, and any error thrown after its own test finished.
The reporter shows these as `simple App boots with the native bridge initialized`
failing "after it had already completed", interleaved with progress lines from
whichever test is actually running. Read the stack trace, not the label. On
2026-09-16 that line was a `PlayerScreen` teardown inside `remote_control`.

To reproduce one file on its own, where attribution is exact, point
`E2E_TEST_TARGET` in `nix/tests/player-e2e.nix` at it locally (for example
`integration_test/remote_control_test.dart`) and run the check as above. Do
not commit that change.
