#!/usr/bin/env bash
#
# Push Build / Android's toolchain to the CI cache, minus the Android SDK.
#
# Usage: scripts/ci-android-shell-push.sh <ciAndroid.shell output path>
# Env:   NIX_CI_PUSH  push.sh, as exported by .github/actions/nix-ci
#
# ciAndroid.shell is devShells.android's inputDerivation, whose output
# references every input of the shell. This pushes each of those inputs
# except the androidenv composition (`androidsdk`): the SDK, NDK, platforms
# and build tools are unfree, Google's licence forbids redistributing them,
# and cache.mydia.dev is publicly readable. The rest is free (Flutter and its
# engine artifacts, the JDK, the Rust toolchain with its Android targets,
# the GTK and media build deps); in practice only the Rust toolchain is new,
# since the player checks already push the others.
#
# A pushed path whose closure reached the SDK would upload it too, so the
# closure is checked first and nothing is pushed if it does. Like push.sh,
# this never fails the job.
set -uo pipefail

shell="$1"
sdk_re='/[a-z0-9]{32}-android(sdk|-sdk-|-ndk)'

mapfile -t inputs < <(nix-store --query --references "$shell" | grep -vxF "$shell" | grep -Ev -- "$sdk_re")
if [ "${#inputs[@]}" -eq 0 ]; then
  echo "::warning::$shell has no inputs to push"
  exit 0
fi

if leaked="$(nix-store --query --requisites "${inputs[@]}" | grep -E -- "$sdk_re")"; then
  echo "::warning::not pushing the Android dev shell: these toolchain paths depend on the unfree SDK:"
  echo "$leaked"
  exit 0
fi

"$NIX_CI_PUSH" "${inputs[@]}"
