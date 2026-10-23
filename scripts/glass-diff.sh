#!/usr/bin/env bash
#
# Render the Liquid Glass lab at a base ref and from the git index, and write
# side-by-side and pixel-diff images per scene. Recording a diff is what lets
# scripts/check-glass-diff.sh pass. Run as `./dev player glass-diff`; see
# player/docs/liquid-glass.md, "Visual diff".
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/glass-paths.sh
. "$root/scripts/glass-paths.sh"

usage() { echo "Usage: ./dev player glass-diff [--base <ref>]" >&2; }

base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:?--base needs a ref}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
[ -n "$base" ] || base="$(git -C "$root" merge-base HEAD origin/master)"
base_sha="$(git -C "$root" rev-parse --verify "$base^{commit}")"

stamp="$(glass_stamp "$root")"
out="$(git -C "$root" rev-parse --path-format=absolute --git-path "glass-diff/$stamp")"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/mydia/glass-lab/$(basename "$root")"
skel="$cache/skel"
mkdir -p "$out" "$cache"
# A run that fails partway must not leave an earlier run's stamp behind: the
# gate accepts this content again only once every scene has been compared.
rm -f "$out/stamp"

# with_tool <binary> <nixpkgs attr> <command...>: run the command, through
# `nix shell` when the binary is not on PATH (as `player flatpak` does).
with_tool() {
  local bin=$1 pkg=$2
  shift 2
  if command -v "$bin" >/dev/null 2>&1; then
    "$@"
  else
    nix shell "nixpkgs#$pkg" -c "$@"
  fi
}
# Not named `magick`: `command -v magick` would find the function itself.
im() { with_tool magick imagemagick magick "$@"; }

export_base() {
  rm -rf "$cache/src-before"
  mkdir -p "$cache/src-before"
  git -C "$root" archive "$base_sha" player/lib player/tool player/shaders |
    tar -x -C "$cache/src-before"
}

# The index, not the working tree: it is what the commit will contain.
export_index() {
  rm -rf "$cache/src-after"
  mkdir -p "$cache/src-after"
  git -C "$root" ls-files -z -- player/lib player/tool player/shaders |
    git -C "$root" checkout-index -z --stdin --prefix="$cache/src-after/"
}

ensure_skeleton() {
  [ -f "$skel/pubspec.yaml" ] && return
  rm -rf "$skel"
  flutter create --platforms=linux --project-name player --offline "$skel" >/dev/null
  printf '  shaders:\n    - shaders/liquid_glass.frag\n' >>"$skel/pubspec.yaml"
}

# assemble <src> <lab-src> <project>: a plugin-free Flutter project named
# `player`, holding the lab from <lab-src> and every lib/ file it reaches
# from <src>. build/ and .dart_tool/ survive, so rebuilds are incremental.
assemble() {
  local src=$1 labsrc=$2 proj=$3 f from dir imp dep
  mkdir -p "$proj"
  cp "$skel/pubspec.yaml" "$skel/analysis_options.yaml" "$proj/"
  [ -d "$proj/linux" ] || cp -r "$skel/linux" "$proj/"
  rm -rf "${proj:?}/lib" "${proj:?}/tool" "${proj:?}/shaders"
  mkdir -p "$proj/shaders"
  if [ ! -f "$src/player/shaders/liquid_glass.frag" ]; then
    echo "assemble: player/shaders/liquid_glass.frag is missing from $src" >&2
    return 1
  fi
  cp "$src/player/shaders/liquid_glass.frag" "$proj/shaders/"
  local -A seen=()
  local queue=("tool/liquid_glass_lab/main.dart")
  while [ ${#queue[@]} -gt 0 ]; do
    f=${queue[0]}
    queue=("${queue[@]:1}")
    [ -n "${seen[$f]:-}" ] && continue
    seen[$f]=1
    case $f in tool/*) from=$labsrc ;; *) from=$src ;; esac
    if [ ! -f "$from/player/$f" ]; then
      echo "assemble: player/$f is missing from $from" >&2
      return 1
    fi
    mkdir -p "$proj/$(dirname "$f")"
    cp "$from/player/$f" "$proj/$f"
    dir=$(dirname "$f")
    while read -r imp; do
      case $imp in
        package:player/*) dep="lib/${imp#package:player/}" ;;
        dart:* | package:*) continue ;;
        *) dep=$(realpath -m --relative-to=/x "/x/$dir/$imp") ;;
      esac
      queue+=("$dep")
    done < <(grep -oE "^(import|export) '[^']+'" "$proj/$f" |
      sed -E "s/^(import|export) '([^']+)'/\2/")
  done
}

# build <project>: a release bundle of the lab; the log stays in the project.
build() {
  (
    cd "$1"
    { flutter pub get --offline || flutter pub get; } >build.log 2>&1
    flutter build linux --release -t tool/liquid_glass_lab/main.dart >>build.log 2>&1
  )
}

# render <project> <scene> <png>
render() {
  local bin="$1/build/linux/x64/release/bundle/player"
  rm -f "$3"
  with_tool xvfb-run xvfb-run xvfb-run -a -s "-screen 0 2560x1800x24" \
    env GDK_SCALE=2 LAB_SNAPSHOT="$3" LAB_SCENE="$2" timeout 120 "$bin" \
    >"$3.log" 2>&1 || true
  if [ ! -s "$3" ]; then
    echo "error: the lab wrote no snapshot for '$2'; see $3.log" >&2
    exit 1
  fi
  rm -f "$3.log"
}

label() { # label <in> <out> <text>
  im "$1" -gravity north -background '#222' -fill white -pointsize 34 \
    -splice 0x60 -annotate +0+12 "$3" "$2"
}

echo "glass-diff: base $(git -C "$root" rev-parse --short "$base_sha"), staged content $stamp"
ensure_skeleton
export_base
export_index

if ! assemble "$cache/src-after" "$cache/src-after" "$cache/after"; then
  echo "error: the staged lab cannot be assembled" >&2
  exit 1
fi
if ! build "$cache/after"; then
  echo "error: the staged lab does not build; see $cache/after/build.log" >&2
  exit 1
fi

# Both sides run the staged lab, so their layouts match and the pixel diff
# means something. A base whose glass API the staged lab no longer compiles
# against, or lacks a file it imports, falls back to its own lab,
# side-by-side only.
shared_lab=1
if ! { assemble "$cache/src-before" "$cache/src-after" "$cache/before" &&
  build "$cache/before"; }; then
  echo "note: the base does not build with the staged lab; using its own lab, no pixel diff" >&2
  shared_lab=0
  if ! { assemble "$cache/src-before" "$cache/src-before" "$cache/before" &&
    build "$cache/before"; }; then
    echo "error: the base lab does not build; see $cache/before/build.log" >&2
    exit 1
  fi
fi

summary=()
compare_failed=0
for scene in grid artwork panel; do
  rm -f "$out/$scene-diff.png"
  before_scene=$scene
  [ "$shared_lab" = 1 ] || before_scene=grid
  render "$cache/before" "$before_scene" "$out/$scene-before.png"
  render "$cache/after" "$scene" "$out/$scene-after.png"
  label "$out/$scene-before.png" "$cache/b.png" "before ($(git -C "$root" rev-parse --short "$base_sha"), $before_scene)"
  label "$out/$scene-after.png" "$cache/a.png" "after (staged, $scene)"
  im "$cache/b.png" "$cache/a.png" -bordercolor '#222' -border 8 +append \
    -resize 50% "$out/$scene-side.png"
  if [ "$shared_lab" = 1 ]; then
    changed=$(im compare -metric AE -fuzz 1% "$out/$scene-before.png" \
      "$out/$scene-after.png" "$out/$scene-diff.png" 2>&1 >/dev/null || true)
    case ${changed%% *} in
      '' | *[!0-9.]*)
        summary+=("$scene: compare failed (${changed:-no output})")
        compare_failed=1
        ;;
      *) summary+=("$scene: ${changed%% *} pixels changed") ;;
    esac
  else
    summary+=("$scene: side-by-side only")
  fi
done

echo
printf '  %s\n' "${summary[@]}"
echo
if [ "$compare_failed" = 1 ]; then
  # No stamp: the gate must not accept a diff that was never computed.
  echo "error: a comparison failed; no diff was recorded" >&2
  exit 1
fi
printf 'base %s\nstamp %s\ncreated %s\nshared_lab %s\n' \
  "$base_sha" "$stamp" "$(date -Is)" "$shared_lab" >"$out/stamp"
echo "Look at these before committing:"
for scene in grid artwork panel; do
  echo "  $out/$scene-side.png"
done
