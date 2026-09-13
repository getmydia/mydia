#!/usr/bin/env bash
# Provision and drive an Android TV emulator, then run the debug app on it.
#
# Runs inside the .#android-tv nix devShell (see ./dev player android tv-run),
# which is the only thing that knows about MYDIA_ANDROID_TV_SDK_ROOT. Two
# Android SDKs are in play and they are deliberately kept apart:
#
#   * MYDIA_ANDROID_TV_SDK_ROOT — the emulator, avdmanager and the API 36
#     android-tv x86_64 system image. Read-only /nix/store content.
#   * ANDROID_SDK_ROOT — the build SDK that Gradle, the NDK linkers and adb
#     come from. Untouched by this script.
#
# Nothing here discovers a host SDK, falls back to Android Studio, or installs
# anything with sdkmanager: the pinned store SDK is complete, and anything
# else would make the run non-reproducible.
#
# Ownership contract: an emulator this script starts is killed on exit; an
# emulator that was already running (matched by AVD name, never by "first adb
# device") is left alone. That is what makes repeated runs cheap and safe.
#
# Usage, from the repo root:  ./dev player android tv-run [flutter run args]
set -euo pipefail

# Versioned AVD name: it prevents a stale image from an older API level being
# silently reused when the pinned SDK moves forward.
AVD_NAME="mydia-tv-api-36"
SYSTEM_IMAGE="system-images;android-36;android-tv;x86_64"
BOOT_TIMEOUT_SECONDS=300
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${MYDIA_ANDROID_TV_SDK_ROOT:?Run through ./dev player android tv-run}"
TV_SDK_ROOT="$MYDIA_ANDROID_TV_SDK_ROOT"
EMULATOR="$TV_SDK_ROOT/emulator/emulator"
# The pinned cmdline-tools release is 13.0; androidenv lays it out under that
# version, not the conventional `latest` symlink Android Studio creates.
AVDMANAGER="$TV_SDK_ROOT/cmdline-tools/13.0/bin/avdmanager"
ADB="${ANDROID_SDK_ROOT:?The Android build shell did not set ANDROID_SDK_ROOT}/platform-tools/adb"

# The emulator and avdmanager resolve an AVD's system image through
# ANDROID_SDK_ROOT/ANDROID_HOME, not by looking beside their own binary. Both
# variables point at the *build* SDK in this shell, which has no system-images
# tree at all, so the AVD would resolve to a missing directory and the emulator
# would die with "Broken AVD system path". The TV tools get the TV root for
# their own invocations only; adb and the Flutter/Gradle build keep theirs.
tv_sdk_env=(
    env
    "ANDROID_SDK_ROOT=$TV_SDK_ROOT"
    "ANDROID_HOME=$TV_SDK_ROOT"
)

for command_path in "$EMULATOR" "$AVDMANAGER" "$ADB"; do
    if [[ ! -x "$command_path" ]]; then
        echo "Error: required Android TV tool is unavailable: $command_path" >&2
        exit 1
    fi
done

if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
    echo "Error: Android TV emulator requires a graphical Wayland or X11 session" >&2
    exit 1
fi

# Only a *matching* emulator counts. `adb devices` also lists physical phones,
# unrelated emulators and offline stubs, and using the first device would
# deploy to one of those instead.
find_avd_serial() {
    local serial name
    while read -r serial state; do
        [[ "$serial" == emulator-* && "$state" == device ]] || continue
        # The emulator console answers with CRLF, so the name arrives as
        # "mydia-tv-api-36\r" and would never compare equal to $AVD_NAME.
        name="$("$ADB" -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | head -n 1 || true)"
        if [[ "$name" == "$AVD_NAME" ]]; then
            printf '%s\n' "$serial"
            return 0
        fi
    done < <("$ADB" devices | tail -n +2)
    return 1
}

# Console ports are even; adb uses port+1. Pinning the console port makes the
# serial (`emulator-<port>`) known before adb lists the device, so cleanup
# cannot follow a later-discovered sibling AVD.
pick_console_port() {
    local port
    for ((port = 5554; port <= 5584; port += 2)); do
        if "$ADB" devices | awk '{print $1}' | grep -qx "emulator-$port"; then
            continue
        fi
        if (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
            continue
        fi
        if (echo >/dev/tcp/127.0.0.1/"$((port + 1))") >/dev/null 2>&1; then
            continue
        fi
        printf '%s\n' "$port"
        return 0
    done
    return 1
}

# Idempotent: create the AVD only when the exact name is absent. The prompt is
# the "custom hardware profile?" question, answered no so the --device profile
# is used as-is. avdmanager writes to the normal ${ANDROID_AVD_HOME:-$HOME/.android/avd}.
#
# The listing is read into a variable rather than piped into `grep -q`: grep
# exits on the first match, and under `pipefail` that early exit can fail the
# pipeline while the AVD *is* present (seen during acceptance as an unnecessary
# re-create of an AVD that already existed).
avd_listing="$("${tv_sdk_env[@]}" "$AVDMANAGER" list avd 2>/dev/null || true)"
if ! grep -q "^[[:space:]]*Name: $AVD_NAME$" <<<"$avd_listing"; then
    echo "Creating Android TV AVD $AVD_NAME..."
    printf 'no\n' | "${tv_sdk_env[@]}" "$AVDMANAGER" create avd \
        --force \
        --name "$AVD_NAME" \
        --package "$SYSTEM_IMAGE" \
        --device tv_1080p
fi

emulator_pid=""
emulator_serial=""
cleanup_serial=""
started_emulator=false
emulator_log="$(mktemp -t mydia-android-tv.XXXXXX.log)"

# Reached on normal exit, error exit, and Ctrl-C. Killing via `adb emu kill`
# asks the emulator to shut down cleanly, and the PID is signalled too: the
# console kill has nothing to reach when the emulator never registered with
# adb, and it can also fail against a wedged console. A pre-existing matching
# emulator has started_emulator=false and is deliberately left up.
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "$started_emulator" == true ]]; then
        if [[ -n "$cleanup_serial" ]]; then
            "$ADB" -s "$cleanup_serial" emu kill >/dev/null 2>&1 || true
        fi
        if [[ -n "$emulator_pid" ]]; then
            kill "$emulator_pid" >/dev/null 2>&1 || true
        fi
    fi
    [[ -n "$emulator_pid" ]] && wait "$emulator_pid" 2>/dev/null || true
    rm -f "$emulator_log"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

emulator_serial="$(find_avd_serial || true)"
if [[ -z "$emulator_serial" ]]; then
    if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        echo "Error: /dev/kvm must be readable and writable to start Android TV" >&2
        echo "Add your user to the kvm group, then start a new login session." >&2
        exit 1
    fi

    # The tv_1080p profile sets hw.gpu.enabled=no, so -gpu auto picks the
    # software GLES translator, and that SwiftShader path segfaulted in
    # gfxstream's RenderThread as soon as the app painted (coredump:
    # libGLESv2.so <- gles2_decoder_context_t::decode). The host GPU path ran
    # the same workload with D-pad input for minutes without a crash, so pin it.
    console_port="$(pick_console_port)" || {
        echo "Error: no free emulator console port in 5554-5584" >&2
        exit 1
    }
    cleanup_serial="emulator-$console_port"
    "${tv_sdk_env[@]}" "$EMULATOR" -avd "$AVD_NAME" -port "$console_port" \
        -no-boot-anim -no-snapshot \
        -gpu host \
        >"$emulator_log" 2>&1 &
    emulator_pid=$!
    started_emulator=true
fi

# One deadline covers registration *and* boot, so a hung first stage cannot
# double the wait the timeout advertises.
deadline=$((SECONDS + BOOT_TIMEOUT_SECONDS))
while [[ -z "$emulator_serial" && $SECONDS -lt $deadline ]]; do
    if [[ -n "$emulator_pid" ]] && ! kill -0 "$emulator_pid" 2>/dev/null; then
        echo "Error: Android TV emulator exited before registering with adb" >&2
        tail -n 80 "$emulator_log" >&2
        exit 1
    fi
    sleep 2
    if [[ -n "$cleanup_serial" ]]; then
        if [[ "$("$ADB" -s "$cleanup_serial" get-state 2>/dev/null | tr -d '\r')" == device ]]; then
            emulator_serial="$cleanup_serial"
        fi
    else
        emulator_serial="$(find_avd_serial || true)"
    fi
done

if [[ -z "$emulator_serial" ]]; then
    echo "Error: timed out waiting for $AVD_NAME to register with adb" >&2
    tail -n 80 "$emulator_log" >&2
    exit 1
fi

# Bounded like the registration wait above: `adb wait-for-device` takes no
# deadline of its own and would hang forever on an emulator that registered
# but never came back online. The same deadline covers both stages.
while [[ $SECONDS -lt $deadline ]]; do
    if [[ "$("$ADB" -s "$emulator_serial" get-state 2>/dev/null | tr -d '\r')" == device ]]; then
        [[ "$("$ADB" -s "$emulator_serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && break
    fi
    sleep 2
done
if [[ "$("$ADB" -s "$emulator_serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != 1 ]]; then
    echo "Error: timed out waiting for Android TV boot on $emulator_serial" >&2
    tail -n 80 "$emulator_log" >&2
    exit 1
fi

# The same contract the app relies on at runtime. A phone-shaped or non-TV
# image would boot and accept the APK, then fail confusingly inside Leanback.
#
# Read the feature list into a variable for the same reason as the AVD listing
# above: `grep -q` exits on the first match, and under `pipefail` that early
# exit can fail the pipeline -- reporting a perfectly good TV image as not
# Leanback.
tv_features="$("$ADB" -s "$emulator_serial" shell pm list features | tr -d '\r')"
if ! grep -qx 'feature:android.software.leanback' <<<"$tv_features"; then
    echo "Error: $emulator_serial is not an Android TV Leanback image" >&2
    exit 1
fi

echo "Android TV ready on $emulator_serial; building Mydia Player..."
cd "$ROOT_DIR/player"
flutter pub get
flutter pub run build_runner build
# The explicit -d is the point of this script: no ambiguous multi-device prompt.
flutter run --debug -d "$emulator_serial" "$@"
