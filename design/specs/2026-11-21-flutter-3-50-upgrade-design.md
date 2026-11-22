# Flutter 3.50 upgrade

## Goal

Move the player from Flutter 3.47.4 to 3.50.1, the latest stable (released
2026-11-20), and adopt it fully: the Android toolchain 3.50 targets, the
breaking changes it introduces, and the move from `package:flutter/material.dart`
and `cupertino.dart` to the standalone `material_ui` and `cupertino_ui`
packages. 3.50 deprecates the old libraries; it does not remove them.

## Context

- `player/.fvmrc` is the single source of the Flutter version. devenv,
  `nix/devShells`, every CI workflow, the Dockerfile's flutter-builder stage and
  the Flatpak build read it, and ci-nix.yml's "Check / Flutter Pin" job rejects a
  version literal anywhere else. `player/flutter-version.nix` resolves
  `flutter<major><minor>` from nixpkgs and throws if its version disagrees with
  `.fvmrc`.
- Neither nixpkgs pin (the main one and `nixpkgs-android`) shipped `flutter350`;
  both move to the same nixos-unstable revision that does, and `devenv.lock`
  follows via `scripts/sync-devenv-nixpkgs.sh`.
- `ee838f6dc` held Flutter at 3.47.4 and named the blockers: 3.50 needs Gradle 9,
  AGP 9 and Kotlin 2.4 on Android, Gradle 9 rejects the read-only Nix-store SDK
  as a project directory, and 3.50 makes `material_ui` the Material library.
- Today: Gradle 8.14, AGP 8.11.1, Kotlin Gradle Plugin 2.2.20, `kotlinOptions`
  with JVM target 17, NDK 28.2. 643 Dart files import
  `package:flutter/material.dart`.

## Shape

Two PRs, each revertible alone. PR 1 changes the toolchain and gets CodeRabbit
review. PR 2 is mechanical import churn over the 150-file limit CodeRabbit
skips, so it gets an omp review.

## PR 1: Flutter 3.50.1 and the toolchain

### Nix-store SDK under Gradle 9 (first task)

Reproduce the failure in the `.#android` dev shell before anything else. Gradle
9 refuses to configure a project whose directory it cannot write, and Flutter's
plugin loader roots SDK plugins such as `integration_test` inside
`FLUTTER_ROOT`, the read-only Nix store. The fix lives in the Android shell hook
in `nix/devShells/flake-module.nix`: copy the SDK's symlink farm (directories
plus symlinks, a few MB) once per store path into a cache directory and export
`FLUTTER_ROOT` to it. It must not ask the user to configure anything.

If no fix holds, PR 1 stops and the decision goes back to the user. A broken
Android build does not ship.

### Version

- `player/.fvmrc`: `3.50.1`.
- `player/pubspec.yaml`: `flutter: '>=3.50.0 <3.51.0'`. The Dart language floor
  stays at 3.6: raising it switches the formatter to the tall style (1553 of
  1979 files change) and enables three lints with 619 hits, so PR 2 raises it.
- Re-resolve `pubspec.lock` and `pubspec.lock.json`, keeping the holds recorded
  in `pubspec.yaml` unless 3.50 lifts their reason.

### Android

- Gradle wrapper and Kotlin Gradle Plugin to what `flutter create` generates on
  3.50.1 (Gradle 9.5.0, KGP 2.4.20). AGP goes to 9.3.3 rather than the
  template's 9.3.1, whose lint crashes on JDK 17 (fixed in 9.3.2).
- cargokit's build task injects `ExecOperations`, since Gradle 9 removed
  `Project.exec()`.
- `kotlinOptions` becomes `kotlin { compilerOptions { jvmTarget } }`, since AGP 9
  drops `kotlinOptions`.
- `gradle.properties`: `android.builtInKotlin=false`, `android.newDsl=false`.
  Built-in Kotlin needs every plugin to support it, which third-party plugins
  decide, so the full opt-in is out of scope.
- Apply the same changes to every local Gradle module
  (`packages/media_kit_libs_macos_video_hdr` if it has one, `rust_builder` and
  cargokit).

### Breaking changes

CI (`nix/ci/player.nix`) and the `dart analyze` pre-commit hook both run
`dart analyze --fatal-infos`, so the deprecated `material.dart` and
`cupertino.dart` imports would fail PR 1 on their own. PR 1 therefore sets
`deprecated_member_use: ignore` under `analyzer: errors:` in
`player/analysis_options.yaml`, with a comment saying PR 2 removes it. Any
other 3.50 deprecation is fixed in PR 1 rather than hidden by that line, which
means checking for them with the line temporarily removed.

Fix each 3.50 break analysis reports (for example the removal of
`ignoringSemantics` from `IgnorePointer` and `AbsorbPointer`).

### Other platforms

Refresh `ios/Podfile.lock` and `macos/Podfile.lock` if pods change. Linux,
Windows, web and Flatpak follow `.fvmrc` with no edits.

### Verification

- Every player CI workflow green: ci-player, Nix CI, Android, iOS, macOS,
  Windows, Linux, Flatpak, AppImage, web player, and the Docker flutter-builder
  stage.
- Local `./dev player android build` in the Nix shell.
- `./dev player glass-diff`, since engine changes can shift shader output.

## PR 2: material_ui and cupertino_ui

Branches from master after PR 1 merges.

- Add `material_ui` and `cupertino_ui` to `player/pubspec.yaml` and to any local
  package that imports Material or Cupertino.
- Run `dart fix --apply --code=migrate_design_widgets` over `lib/`, `test/`,
  `integration_test/` and the local packages, then finish what it misses by hand.
- Regenerate build_runner output. If a generator still emits the old import,
  leave the generated file alone and say so in the PR.
- Raise the Dart floor to 3.14, run `dart format` over the tree (tall style), and
  `dart fix --apply` for `unnecessary_underscores`, `prefer_initializing_formals`
  and `use_null_aware_elements`, each as its own mechanical commit.
- Guard: remove PR 1's `deprecated_member_use: ignore`. `--fatal-infos` in CI
  and the pre-commit hook then rejects any new `package:flutter/material.dart`
  or `cupertino.dart` import, with no custom script.
- Commits split so the `dart fix` output stays apart from hand edits.
- `./dev player glass-diff` (the pre-commit hook requires it because the glass
  widgets change). Expected result: no visual difference.

### Verification

Full player test suite, `flutter analyze` clean, every platform workflow green,
omp code review.

## Out of scope

- Built-in Kotlin and `android.newDsl=true`.
- Lifting package holds whose reason 3.50 does not change.
- Any UI change beyond what the migration forces.
