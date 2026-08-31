# Player packaging: Windows, iOS, fastlane

## The Windows player ships without the VC++ runtime

A Flutter Windows release build links against the Visual C++ 2015-2022 runtime
(`msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`), which is not part of a
clean Windows 11 install. Nothing in mydia ships or installs it.

`player/windows/installer.iss` has no redist handling at all: `[Files]` globs
`{#BuildDir}\*` into `{app}` and there is no `[Run]` entry for
`vc_redist.x64.exe`. `PrivilegesRequired=lowest` means a per-user install with no
UAC, so the installer could not run the redist even if it wanted to. The
app-local fix is the compatible one: copy the three runtime DLLs into the Release
dir in CI, where both the raw `mydia-player-windows-release` artifact and the Inno
Setup installer pick them up automatically. Microsoft's redist rights permit
app-local deployment.

Confirmed 2026-08-25 by running the CI `mydia-player-windows-release` bundle on a
fresh Windows 11 VM, where it fails immediately with "msvcp140.dll was not found".
Grepping `*.md`, `*.yml`, `*.iss` and `*.dart` for `vc_redist|msvcp140` returns
nothing, so the requirement is undocumented as well as unhandled.

Developer machines and `windows-latest` CI runners already have the redist, so
every build and automated check passes. Only a clean end-user machine hits it,
which is why it can survive releases unnoticed. Until this lands, testing a
Windows build on a fresh VM needs `vc_redist.x64.exe`
(https://aka.ms/vs/17/release/vc_redist.x64.exe) run once first.

## Getting a Windows VM for player testing

`compose.windows.yml` at the repo root runs a `dockurr/windows` VM. Web viewer on
:8006, RDP on :3389, user `Docker` with password `password`. Windows installs
itself unattended, which took about 20 minutes on this machine, most of it the
8.4 GB ISO.

Do not build inside the VM. Player CI already publishes a self-contained
`mydia-player-windows-release` artifact of about 40 MB, carrying its own
`flutter_windows.dll`, `libmpv-2.dll` and `mydia_player_p2p.dll`. Drop it in
`player/build/windows-ci/` and it appears in the guest at
`\\host.lan\Data\build\windows-ci\`, because compose mounts `./player` as `/data`
and samba exports `/data` as the `Data` share. That skips the roughly 20 minutes
`player/windows-vm-scripts/install.bat` spends on Chocolatey, Flutter and the VS
build tools.

A freshly installed Windows is missing two things the player needs. One is the
VC++ runtime above, which is a real shipping bug. The other is most root CAs:
pairing fails with
`HandshakeException ... CERTIFICATE_VERIFY_FAILED unable to get local issuer certificate`.
Windows ships a minimal root store and fetches the rest on demand through
Automatic Root Certificates Update, triggered by CryptoAPI chain building. Dart
reads the local store snapshot and never triggers that fetch, so it cannot reach
GTS Root R4 and the relay's chain does not validate. Fix from the guest's
PowerShell with no admin needed:
`Invoke-WebRequest https://relay.mydia.dev -UseBasicParsing`. A 404 is the success
signal, meaning TLS completed and the relay simply has no route at `/`. Opening
the URL once in Edge does the same. Relaunch the player afterwards, since Dart
snapshots the trust store at startup.

Before blaming either on the relay, check the server chain from Linux with
`openssl s_client -connect relay.mydia.dev:443 -servername relay.mydia.dev -showcerts`.
It serves a complete chain and verifies clean, and the pairing path in
`player/lib/core/relay/relay_api_client.dart` uses a bare `http.Client()` with no
pinning, so any cert failure there is the client's trust store.
`pinned_http_client.dart` is for your own instance's self-signed cert, not the
relay.

Two signals mislead you while it installs, and both look authoritative:

- "Windows started successfully" in the container log means QEMU booted, not that
  Setup finished. Waiting on it returns in seconds, long before the guest exists.
  Real progress shows as growth in `du -sh data.img` inside the volume.
- dockurr's own `/run/check.sh` guest probe (`curl http://172.30.0.2:80`) never
  answered here, even with Windows fully booted and usable. Do not use it as a
  readiness signal on this host; look at the screen on :8006.

They are wrong in opposite directions, so an automated wait either fires instantly
or never.

This host is btrfs everywhere, which the image warns about on startup. Disable
copy-on-write on the volume before Setup writes to the disk image, or the install
runs slowly and can corrupt. `chattr` is not on NixOS's system PATH; it lives at
`/nix/store/*e2fsprogs*/bin/chattr`. The compose file header carries the exact
recipe.

## fastlane lockfiles must resolve under Ruby 3.2

`release.yml` runs both fastlane jobs with `ruby/setup-ruby@v1` at
`ruby-version: '3.2'`. If you regenerate `player/ios/Gemfile.lock` or
`player/android/Gemfile.lock` with a newer local Ruby (devenv ships 3.4), bundler
on the runner discards the lockfile and re-resolves, then fails on whichever gem
needs a newer Ruby. Fixing one gem surfaces the next: pinning `excon < 1.7.0`
(needs 3.3) produced `rbs 4.2.0` (needs 3.3) on the following run.

Resolve in a matching container instead, and then no pins are needed at all:

```bash
docker run --rm -v "$PWD/player/android:/w" -w /w ruby:3.2 \
  sh -c "bundle lock --update; bundle lock --add-platform x86_64-linux; bundle lock --add-platform arm64-darwin-24"
```

Under Ruby 3.2 bundler picks `excon 1.6.0` and `rbs 4.1.3` on its own. Both
`PLATFORMS` entries are required: `x86_64-linux` for the ubuntu CI runners (the
lockfiles historically listed only `arm64-darwin-24` and `ruby`) and
`arm64-darwin-24` for the macOS iOS builds.

Ruby 3.2 went EOL in March 2026, and fastlane 2.238.0 warns it will soon require
3.3.0 or newer. Bumping `release.yml` would remove this whole class of problem,
but it changes the workflow that signs and ships players.

Verify a change the way CI will:

```bash
docker run --rm -e FASTLANE_OPT_OUT_USAGE=1 -v "$PWD/player/ios:/w" -w /w ruby:3.2 \
  sh -c "bundle install --jobs 4 && bundle exec fastlane lanes"
```

## Flutter's iOS deployment-target migrator only raises

`packages/flutter_tools/lib/src/ios/migrations/ios_deployment_target_migration.dart`
in the Flutter SDK runs on every `flutter build ios` and does two things worth
knowing before touching an iOS deployment target.

It only raises, never lowers. It rewrites `IPHONEOS_DEPLOYMENT_TARGET` and
`platform :ios,` values of 8.0, 9.0, 11.0 and 12.0 up to 13.0 and leaves anything
else untouched, so setting a target above 13.0 is safe.

It deletes `MinimumOSVersion` from `ios/Flutter/AppFrameworkInfo.plist` when that
key holds 8.0, 9.0, 11.0, 12.0 or 13.0, replacing it with an empty string rather
than bumping it. Current templates omit the key entirely, so `App.framework` takes
its minimum from the build setting. A copy still sitting in the repo is dead
weight that Flutter strips at build time, so it never reaches a shipped artifact
and is misleading to read.

The match is on exact text including two-space indentation, so a reformatted plist
silently stops being migrated.

The practical consequence: the app binary's `MinimumOSVersion` comes from the
project-level `IPHONEOS_DEPLOYMENT_TARGET` in `project.pbxproj`, not from the
Podfile and not from that plist. Chasing an ITMS-90068 warning means changing the
pbxproj, and the other files matter only for keeping Pods consistent.

Verified against the SDK pinned by `player/.fvmrc` on 2026-08-07 while fixing
ITMS-90068 (PR #367). No PR-level iOS build exists to catch a mistake here:
`ci-player.yml` covers Windows, macOS, Linux and Android, and iOS builds only
inside `release.yml`.
