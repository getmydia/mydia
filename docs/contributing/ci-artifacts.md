# Using CI builds

Every push to `master` or `main`, and every pull request, that touches `player/`,
`native/`, `priv/graphql/schema.graphql`, `rust-toolchain.toml` or
`.github/workflows/ci-player.yml` produces downloadable Windows and macOS player
builds from the `ci-player.yml` workflow. A change that only edits translations
(`player/lib/l10n/app_*.arb` other than `app_en.arb`) does not trigger it, and
neither does anything outside those paths, so there is nothing to download for
them. The Android APK comes from the main `ci.yml` workflow, which builds it
on every push and pull request. These builds are the fastest way to try a change
before it reaches a release.

CI builds are not release builds. They are ad-hoc signed and never notarized, so
Sparkle auto-update does not work on them. If you are testing the updater, use a
release DMG instead.

Artifacts are kept for 7 days.

## Finding a run

```bash
gh run list --workflow=ci-player.yml -R getmydia/mydia --limit 10   # Windows, macOS
gh run list --workflow=ci.yml -R getmydia/mydia --limit 10          # Android
```

Take the run ID from the leftmost column of the row you want.

## macOS

```bash
gh run download <run-id> -R getmydia/mydia -n mydia-player-macos-app
ditto -x -k mydia-player-macos.zip .
xattr -cr "Mydia Player.app"
open "Mydia Player.app"
```

There are two archives here, which is expected. `gh run download` unwraps
GitHub's own artifact zip and leaves `mydia-player-macos.zip` on disk. That inner
archive is the app bundle, packaged with `ditto` so its framework symlinks
survive the trip. Extract it with `ditto -x -k` or by double clicking it in
Finder. Both preserve symlinks; some third party unzip tools do not, and a
bundle whose symlinks have been replaced by copies will not launch.

`xattr -cr` clears the quarantine attribute. Quarantine is set by the
downloading application, not unconditionally by macOS: browsers and other
LaunchServices-aware clients set it, but `gh run download` does not, so for the
steps above this command is usually a no-op. Run it anyway; it is harmless when
there is nothing to clear, and it is what makes the app launch if you instead
download the artifact through the Actions UI in a browser. Without it,
Gatekeeper refuses to launch a quarantined app, because a CI build carries an
ad-hoc signature rather than a notarized Developer ID one.

## Linux

CI publishes no Linux build. It still compiles the player for Linux on every
change, but in a Nix build whose libraries live in the Nix store, so the result
runs nowhere else. To try a change on Linux, build it from your checkout, or
use the tarball, AppImage or Flatpak from a release.

## Windows

```bash
gh run download <run-id> -R getmydia/mydia -n mydia-player-windows-release -D mydia-player
```

Run `mydia-player\mydia-player.exe` from the extracted directory. The build is
unsigned, so SmartScreen shows a warning; choose "More info" then "Run anyway".

## Android

```bash
gh run download <run-id> -R getmydia/mydia -n mydia-player-android-apk
adb install -r app-release.apk
```

The APK is signed with a debug key, so it will not upgrade over a Play Store or
release install. Uninstall the release build first if `adb install` reports a
signature mismatch.
