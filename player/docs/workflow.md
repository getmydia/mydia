# Player workflow: codegen, tests, analyze, commits

## Run ./dev player setup first, in every new worktree

`*.graphql.dart` and `*.g.dart` are gitignored, so a fresh worktree has none of
them and nothing compiles until codegen runs. Measured on a fresh worktree: 0
generated files against 26 in the main checkout, with `./dev player setup`
writing 91 outputs in about 53s.

The gap hides until the first commit. A widget test run against a single file
passes, because its imports never reach generated code, so the work looks
finished. Then the whole-project `dart analyze --fatal-warnings` pre-commit hook
rejects the commit with hundreds of `Target of URI hasn't been generated` errors
in files you never opened, and it reads like the branch is broken. Any plan handed
to another agent needs this as an explicit task 0.

Codegen must go through `flutter pub run build_runner build`, never
`dart run build_runner`. `dart pub` cannot see the Flutter SDK, so version solving
fails on the `integration_test` SDK dependency with "the Flutter SDK is not
available".

`./dev player setup` can also leave codegen incomplete, and the symptom is
misleading. A partially-generated worktree fails around 39 test files at load
time while about 1479 still pass, so the run looks like a broad regression rather
than a missing file. The real error only shows when you run one failing file
directly: `Error when reading 'lib/graphql/mutations/download_options.graphql.dart':
No such file or directory`. Before diagnosing any mass "loading <file>" failure as
a code regression, run `./dev flutter pub run build_runner build`. It rewrote the
missing outputs in 20s and took the suite from 1479 passed / 39 failed to 1673
passed. Codegen state can degrade between runs in the same worktree, so a suite
that was green an hour ago proves nothing.

As of 2026-08-09 build_runner prints
`These options have been removed and were ignored: --delete-conflicting-outputs`,
so drop that flag.

## Always pass --concurrency=1 to the test suite

At default concurrency the player suite silently drops 2 to 4 test files while
still exiting 0 and printing "All tests passed!". Reproduced across several runs;
`--concurrency=1` reliably ran every file. This is not a flake you can retry past,
because the failure mode is silence. When a subagent or plan step reports green,
check the command carried the flag. The full suite was about 2115 tests as of
2026-08-12, so a materially lower number is the symptom.

```
./dev flutter test --concurrency=1 [paths]
```

There is no `./dev player test` and no `./dev player analyze`. Both were invented
while writing a plan on 2026-08-12 and shipped into an agent prompt file, breaking
the first player task. `./dev player` takes only setup, build, icons, shell,
restart, e2e, logs, android and macos; everything else goes through
`./dev flutter <args>`, which runs in the player directory. The Dart package is
named `player`, so test imports are `package:player/...`, never
`package:mydia_player/...`.

## analyze exits 1 on a standing backlog

`./dev flutter analyze` exits 1 on the standing info-level backlog, so never chain
`./dev flutter analyze && ./dev flutter test ...`; the `&&` silently skips the test
run. Judge it with `2>&1 | grep -c "error •"` against the baseline rather than
expecting "No issues found!". `flutter analyze` reports roughly 1557 pre-existing
info-level lints, so read the error and warning counts rather than the total.

The gate that actually blocks is `dart analyze --fatal-warnings` in the pre-commit
hook, and it runs over the whole player project rather than staged files. A
breaking change to a shared Dart type therefore cannot be committed separately
from the consumers it breaks. Plans that stage "change the model in task N, fix
its callers in task N+3" do not work here: either land them together, or have the
breaking task make a minimal compile-only edit to each consumer. A two-step widget
extraction works fine in the other order, adding the new public widget in one
commit while the private original stays in use, then deleting the original and
switching callers next.

## dart format writes by default

`--set-exit-if-changed` only sets the exit code; it does not make the command
read-only. Pass `--output=none` for a check. Running
`dart format --set-exit-if-changed --line-length 80 lib test` over the whole
package reformatted 53 files on disk in one shot.

Worse than noise, reformatting the whole tree breaks the build. It splits the
declaration under `// ignore: unused_field` on `_certVerifier` in
`lib/core/p2p/connection_manager.dart` so the ignore stops applying, and the
`dart analyze --fatal-warnings` pre-commit hook then rejects the commit over a
file you never touched.

The whole-tree check is misleading because the `dart-format` pre-commit hook runs
only on staged files, so the package carries a large backlog of pre-existing
format drift the hook never trips on. Scope format checks to the files you
changed:

```
dart format --output=none --set-exit-if-changed --line-length 80 <your files>
```

## The format hook drops your file out of its own commit

On Dart commits the `dart-format` hook rewrites your file during the commit, and
that rewrite lands unstaged, so the file drops out of the commit that triggered
it. You can stage perfectly and still lose the file.

Observed 2026-08-17 on two consecutive player commits (`e763ac50`, `35d9536a`),
each touching a `.dart` file that was not already dart-format clean. Both times
the first `git commit` exited 0 while omitting the file, and both were caught only
by a follow-up `git show --stat`.

On any commit touching `.dart` files, treat `git show --stat` as mandatory and
expect to `git add` and re-commit once. Writing the file already dart-format clean
avoids it entirely. Spell this out in any plan or subagent brief that ends in a
Dart commit.

## Widget tests must open Hive with bytes:

Any `testWidgets` test exercising code that calls Hive, such as
`SubtitleLanguagePrefs.load` or `.save`, must use
`Hive.openBox<T>(name, bytes: Uint8List(0))` rather than `Hive.init(tempDir)` plus
`openBox(name)`. `bytes:` selects `StorageBackendMemory`, where `initialize`,
`writeFrames`, `flush` and `close` are all `Future.value()`. A disk-backed box
leaves a real file write outstanding inside `testWidgets`' fake-async zone, which
never drives it.

The failure is badly mislabeled. The test hangs until the 10-minute per-test
timeout, and because a timed-out test never releases the binding, the next tests
in the same file fail with `Failed assertion: '!inTest': is not true`. One hang
reads as three unrelated broken tests and the file takes 20+ minutes. Wrapping
setup in `tester.runAsync()` is not enough, since the write that hangs is the one
a later `tester.tap` triggers and you cannot `pump` inside `runAsync`. Use
`bytes:` plus `addTearDown(box.close)`; `deleteFromDisk` throws
`UnsupportedError` on a memory box. Plain `test()` cases are unaffected and may
use a real temp-dir box, which is what `subtitle_language_prefs_test.dart` does.

## Two tests that lie about their state

`offline_sentinel_streaming_fallback_test.dart` can fail during a local full-suite
run with
`Bad state: Tried to read a provider from a ProviderContainer that was already disposed`,
while passing 2/2 as the only file and passing the `Test / Player` CI job. That is
cross-test pollution in the local run. Re-run the file alone; if it passes in
isolation, confirm against CI rather than bisecting the suite.

`test/presentation/widgets/video_controls/chrome_panel_golden_test.dart` is gated
`@TestOn('mac-os')`, so it skips silently on Linux and on CI's ubuntu-latest.
Changes to `DepthTokens.playerChromeTint` or anything feeding
`GlassSurface.playerChrome` invalidate its committed goldens with no Linux run
noticing. Regenerate on a Mac with
`cd player && flutter test --update-goldens <path>`.

## A worktree-built APK cannot replace a release install

`player/android/app/build.gradle.kts` signs release builds with the key in
`android/key.properties` if that file exists, and silently falls back to the debug
keystore if it does not. `key.properties` is gitignored and is present in neither
the main checkout nor any worktree, so `./dev player android build` always
produces a debug-signed APK on this machine.

A tablet carrying a release-signed build from a GitHub release refuses the local
one:

```
adb: failed to install ...: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE:
Package dev.mydia.player signatures do not match previously installed version]
```

`adb install -r` cannot get past this. The options are `adb uninstall
dev.mydia.player` first, which wipes login, p2p pairing and downloads and should
be confirmed with the user, or changing `applicationId` for a side-by-side
install. Once the device holds a debug-signed build, subsequent `adb install -r`
from the same machine works, since they share `~/.android/debug.keystore`.

Budget about 10 minutes for `./dev player android build` on a cold worktree, since
it cross-compiles `mydia_player_p2p` for four Android targets, and about 1 minute
when the Rust artifacts are cached. Output is 173 MB at
`player/build/app/outputs/flutter-apk/app-release.apk`. There is no deep-link
intent filter (`MAIN`/`LAUNCHER` only), so the app cannot be driven to a specific
title over adb; a human has to tap through.
