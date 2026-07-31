# Using CI builds

Every push to `master`, and every pull request touching `player/`, `native/`, or
`.github/workflows/ci-player.yml`, produces downloadable player builds. They are
the fastest way to try a change before it reaches a release.

CI builds are not release builds. They are ad-hoc signed and never notarized, so
Sparkle auto-update does not work on them. If you are testing the updater, use a
release DMG instead.

Artifacts are kept for 7 days.

## Finding a run

```bash
gh run list --workflow=ci-player.yml -R getmydia/mydia --limit 10
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

`xattr -cr` clears the quarantine attribute macOS applies to anything
downloaded. Without it Gatekeeper refuses to launch the app, because a CI build
carries an ad-hoc signature rather than a notarized Developer ID one. You only
need to do this once per download.

## Linux

```bash
gh run download <run-id> -R getmydia/mydia -n mydia-player-linux-bundle -D mydia-player
chmod +x mydia-player/mydia-player
./mydia-player/mydia-player
```

The artifact contains the contents of the build bundle, so pass `-D` to give it
a directory of its own. The bundle links against libmpv and GTK 3 rather than
shipping them, so both must already be installed. On Debian and Ubuntu the GTK
package is `libgtk-3-0`; the libmpv runtime package is `libmpv2` on Ubuntu 24.04
and later and `libmpv1` on older releases, so install whichever your release
provides:

```bash
sudo apt-get install libgtk-3-0
sudo apt-get install libmpv2 || sudo apt-get install libmpv1
```

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
