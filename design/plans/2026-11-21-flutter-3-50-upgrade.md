# Flutter 3.50 Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the player from Flutter 3.47.4 to 3.50.1 and off the deprecated `flutter/material.dart` and `cupertino.dart` libraries.

**Architecture:** Two PRs. PR 1 (Tasks 1-5, branch `build/flutter-3-50`) bumps `.fvmrc`, moves Android to Gradle 9 / AGP 9 / Kotlin 2.4, makes Gradle 9 build from the Nix-store SDK, and fixes 3.50 breaks while temporarily ignoring `deprecated_member_use`. PR 2 (Tasks 6-8, branch `build/flutter-3-50-material-ui` cut from master after PR 1 merges) runs the `material_ui` migration and removes the ignore.

**Tech Stack:** Flutter 3.50.1 / Dart 3.14, Gradle 9, AGP 9, Kotlin Gradle Plugin 2.4, Nix (nixos-unstable `flutter350`), devenv.

**Spec:** `design/specs/2026-11-21-flutter-3-50-upgrade-design.md`

## Global Constraints

- `player/.fvmrc` is the only file that names a Flutter version; "Check / Flutter Pin" rejects version literals in any build or CI file, including comments.
- Both nixpkgs pins move to one nixos-unstable revision that ships `flutter350` 3.50.1; `devenv.lock` follows via `scripts/sync-devenv-nixpkgs.sh`.
- `android.builtInKotlin=false` and `android.newDsl=false` stay as they are (already present in `player/android/gradle.properties`).
- No user-side environment setup: any Nix-store SDK fix lives in `nix/devShells/flake-module.nix`, `devenv.nix` or the `./dev` wrapper.
- Package holds recorded in `player/pubspec.yaml` stay unless 3.50 removes their stated reason.
- CI and the pre-commit hook run `dart analyze --fatal-infos`.
- Run every `git commit` via `direnv exec . git commit -F <msgfile>` from the worktree, then `git show --stat HEAD`.
- Never `--no-verify`. Liquid Glass changes need `./dev player glass-diff`.

## Review Focus

- A fresh clone in the `.#android` shell with no prior `~/.gradle` or Flutter cache: `./dev player android build` must succeed with no manual step (Task 1 step 5 runs it from a clean `GRADLE_USER_HOME`).
- GitHub Actions Android (subosito Flutter, writable SDK) must keep working with whatever Task 1 changes for Nix; the fix must be a no-op there (Task 5 checks player-android.yml).
- Flatpak and Docker builds fetch the SDK from `.fvmrc` with no edits; a stale cached SDK layer must not mask a failure (Task 5 checks both workflows ran, not skipped).
- `deprecated_member_use: ignore` must not outlive PR 2 (Task 8 step 1 asserts it is gone).
- Golden or glass output drift from the engine bump must be explained, not regenerated blindly (Task 4 and Task 8 run glass-diff and inspect any diff).

---

## PR 1 (branch `build/flutter-3-50`)

### Task 1: Gradle 9 builds from the read-only Nix-store SDK

**Files:**
- Modify: `player/.fvmrc` (`"flutter": "3.50.1"`)
- Modify: `nix/devShells/flake-module.nix` (Android shell hook), and/or `devenv.nix` and `./dev` (`player android` case) if the fix belongs there
- Modify: `player/android/gradle/wrapper/gradle-wrapper.properties`, `player/android/settings.gradle.kts` (needed to reproduce)

**Interfaces:**
- Produces: an `.#android` shell in which `flutter build apk` on 3.50.1 succeeds without writes to `/nix/store`.

- [ ] **Step 1:** Set `.fvmrc` to `3.50.1` and `player/pubspec.yaml:23` to `flutter: '>=3.50.0 <3.51.0'` (otherwise `pub get` refuses the new SDK); the Dart floor stays at 3.6 until Task 6. Set the Gradle wrapper `distributionUrl`, the `com.android.application` version and the `org.jetbrains.kotlin.android` version in `settings.gradle.kts` to exactly what `flutter create` produces on 3.50.1: run `flutter create --platforms=android /tmp/claude-1000/flutter350_probe (an underscore: Flutter rejects a hyphenated project name)` inside `./dev player android shell` and copy the three values from the probe's `android/` files.
- [ ] **Step 2:** In `./dev player android shell`, run `cd player && flutter pub get && flutter build apk --debug`. Expected: FAIL. Record the exact Gradle error and the store path it names in the commit message.
- [ ] **Step 3:** Fix it in the shell hook. Preferred order, stop at the first that works: (a) a Gradle/Flutter setting that relocates the included build's project cache (`--project-cache-dir` via `GRADLE_OPTS`/`gradle.properties` if Gradle 9 honours it for included builds); (b) the shell hook copies `$FLUTTER_ROOT/packages/flutter_tools/gradle` into a writable cache dir keyed on the Flutter store path and points `flutter.sdk`/the plugin loader at it; (c) a writable full SDK copy (reflink/`cp -r` once per store path into `$XDG_CACHE_HOME/mydia/flutter-<hash>`) exported as `FLUTTER_ROOT` and first on `PATH`. Comment the hook with the Gradle error it prevents. If none works, stop and report to the user (spec: PR 1 does not ship a broken Android build).
- [ ] **Step 4:** Re-run step 2's command. Expected: `Built build/app/outputs/flutter-apk/app-debug.apk`.
- [ ] **Step 5:** Run `GRADLE_USER_HOME=$(mktemp -d) ./dev player android build`. Expected: release APK at `player/build/app/outputs/flutter-apk/app-release.apk`, and `./scripts/check-apk-abis.sh player` passes.
- [ ] **Step 6:** Commit `build(player): Flutter 3.50.1 on Gradle 9 from the Nix-store SDK`.

### Task 2: Android toolchain syntax for AGP 9

**Files:**
- Modify: `player/android/app/build.gradle.kts:4-29`
- Modify: `player/rust_builder/android/build.gradle` (`classpath 'com.android.tools.build:gradle:7.3.0'`, `compileSdkVersion 34`, Java 1.8)

**Interfaces:**
- Consumes: Task 1's AGP/Kotlin versions.

- [ ] **Step 1:** Replace `kotlinOptions { jvmTarget = ... }` with a top-level `kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }`. Keep `id("kotlin-android")` (built-in Kotlin is out of scope).
- [ ] **Step 2:** In `rust_builder/android/build.gradle` drop the AGP 7.3.0 `buildscript` classpath (the app's AGP applies), keep `compileSdkVersion` at `flutter.compileSdkVersion` if available or 36, and move Java to 17. Leave cargokit's `plugin.gradle` alone unless the build reports it.
- [ ] **Step 3:** Run `./dev player android build`. Expected: success with no `kotlinOptions` or AGP deprecation errors; warnings listed in the commit message.
- [ ] **Step 4:** Commit `build(player): AGP 9 Kotlin DSL and rust_builder Gradle`.

### Task 3: pubspec and lockfiles on 3.50.1

**Files:**
- Modify: `player/pubspec.yaml` (hold comments only; constraints changed in Task 1)
- Modify: `player/pubspec.lock`, `player/pubspec.lock.json`, `player/ios/Podfile.lock`, `player/macos/Podfile.lock` (only if pods change)

- [ ] **Step 1:** Run `cd player && flutter pub upgrade --major-versions=false`; then regenerate `pubspec.lock.json` the way the repo does (find the generator with `git log -1 --format=%H -- player/pubspec.lock.json` and follow that commit).
- [ ] **Step 2:** Re-check each hold comment in `pubspec.yaml` against 3.50; lift only those whose reason is gone, and say which in the commit message.
- [ ] **Step 3:** Run `cd player && flutter pub run build_runner build --delete-conflicting-outputs`. Expected: success.
- [ ] **Step 4:** Commit `build(player): resolve packages on Flutter 3.50.1`.

### Task 4: 3.50 breaking changes and the temporary analyzer ignore

**Files:**
- Modify: `player/analysis_options.yaml:31-32` (add `deprecated_member_use: ignore` under `errors:` with comment "Flutter 3.50 deprecates flutter/material.dart and cupertino.dart; the material_ui migration PR removes this line.")
- Modify: whatever files analysis reports

- [ ] **Step 1:** Without the ignore, run `cd player && dart analyze --fatal-infos 2>&1 | grep -v "material.dart\|cupertino.dart"`. Expected: the list of non-import 3.50 diagnostics. Fix each (for example remove `ignoringSemantics:` from `IgnorePointer`/`AbsorbPointer`, using `ExcludeSemantics` where the semantics were meant to be dropped).
- [ ] **Step 2:** Add the ignore line. Run `dart analyze --fatal-infos`. Expected: `No issues found!`.
- [ ] **Step 3:** Run `./dev player test`. Expected: all pass; any golden failure is inspected and explained in the commit before updating.
- [ ] **Step 4:** Run `./dev player glass-diff`. Expected: pass, or a diff that is inspected and attributed to the engine.
- [ ] **Step 5:** Commit `fix(player): Flutter 3.50 breaking changes`.

### Task 5: PR 1 out

- [ ] **Step 1:** Run `git diff --name-only origin/master...` and `get_risk` with `changed_files`; handle `missing_cochanges`.
- [ ] **Step 2:** Confirm no version literal leaked: run the Flutter Pin check locally (`grep -n "flutter-pin" -A20 .github/workflows/ci-nix.yml` to find its command).
- [ ] **Step 3:** Push `git push -u origin HEAD:build/flutter-3-50`, open the PR (not draft, no auto-merge), confirm `headRefOid` matches.
- [ ] **Step 4:** Wait on CI with Monitor. Expected green and actually run (not skipped): ci-player, ci-nix, player-android, player-ios, player-macos, player-windows, player-linux, player-flatpak, player-appimage, deploy-web-player (build), ci-docker flutter-builder.
- [ ] **Step 5:** Address CodeRabbit findings, merge by hand after the user agrees.

## PR 2 (branch `build/flutter-3-50-material-ui` from master after PR 1)

### Task 6: material_ui and cupertino_ui dependencies plus dart fix

**Files:**
- Modify: `player/pubspec.yaml`, `player/pubspec.lock`, `player/pubspec.lock.json`
- Modify: `player/rust_builder/pubspec.yaml`, `player/packages/media_kit_libs_macos_video_hdr/pubspec.yaml` only if they import Material/Cupertino
- Modify: ~643 Dart files under `player/lib`, `player/test`, `player/integration_test`, `player/packages`

- [ ] **Step 1:** `flutter pub add material_ui cupertino_ui` in each package that needs them. Raise `player/pubspec.yaml`'s Dart floor to `'>=3.14.0 <4.0.0'`, run `dart format lib test integration_test` and commit that alone (`style(player): Dart 3.14 tall formatting`); then `dart fix --apply --code=unnecessary_underscores --code=prefer_initializing_formals --code=use_null_aware_elements`, committed alone.
- [ ] **Step 2:** Run `dart fix --apply --code=migrate_design_widgets` in `player/` and each local package. Run `dart format` on the result.
- [ ] **Step 3:** Commit this mechanical output alone: `refactor(player): dart fix migrate_design_widgets`.

### Task 7: Hand fixes and codegen

- [ ] **Step 1:** Remove the ignore temporarily and run `dart analyze --fatal-infos`. Fix each remaining `material.dart`/`cupertino.dart` diagnostic by hand.
- [ ] **Step 2:** Run `flutter pub run build_runner build --delete-conflicting-outputs`. If a generator still emits an old import, leave the generated file and note it for the PR body.
- [ ] **Step 3:** Commit `refactor(player): finish the material_ui migration by hand`.

### Task 8: Remove the ignore, verify, PR 2 out

**Files:**
- Modify: `player/analysis_options.yaml` (delete `deprecated_member_use: ignore` and its comment)

- [ ] **Step 1:** Delete the line. Run `grep -n deprecated_member_use player/analysis_options.yaml`. Expected: no output. Run `dart analyze --fatal-infos`. Expected: `No issues found!`. Run `grep -rln "package:flutter/material.dart\|package:flutter/cupertino.dart" player/lib player/test player/integration_test player/packages`. Expected: only generated files noted in Task 7, or none.
- [ ] **Step 2:** `./dev player test`, then `./dev player glass-diff`. Expected: pass, no visual difference.
- [ ] **Step 3:** Commit `build(player): fail analysis on flutter/material.dart imports`.
- [ ] **Step 4:** Push, open the PR, run an omp code review (CodeRabbit skips >150 files), wait on the same workflow list as Task 5 step 4, merge by hand after the user agrees.
