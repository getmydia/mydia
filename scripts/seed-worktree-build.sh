#!/usr/bin/env bash
# Seed a fresh git worktree's build outputs from the main checkout, so its
# first shell does not compile every Hex dependency and both Rust NIFs from
# scratch (~6 minutes for dev, another ~2.5 for test).
#
# Runs as the devenv task mydia:seed-build, before mydia:deps. It does
# nothing unless this checkout is a linked worktree with no deps/ yet and the
# main checkout has one.
#
# Copies deps/, the dependency apps under _build/{dev,test}/lib (never the
# mydia app itself, which a running dev server in the main checkout may be
# rewriting, and which recompiles either way), the tailwind/esbuild binaries,
# and native/*/target. Mix and cargo then rebuild only what differs from the
# main checkout. On a copy-on-write filesystem (btrfs, XFS with reflink) the
# copy is instant and shares disk blocks; elsewhere `cp --reflink=auto` falls
# back to an ordinary copy, still faster than compiling.
set -euo pipefail

root=$(pwd -P)
[ -e deps ] && exit 0

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
main=$(dirname "$common")
[ "$main" = "$root" ] && exit 0
[ -d "$main/deps" ] || exit 0

echo "Seeding build outputs from $main"
start=$SECONDS
copy() { cp -a --reflink=auto "$@"; }

copy "$main/deps" deps

for env in dev test; do
    [ -d "$main/_build/$env/lib" ] || continue
    mkdir -p "_build/$env/lib"
    for app in "$main/_build/$env/lib"/*; do
        [ "$(basename "$app")" = mydia ] && continue
        copy "$app" "_build/$env/lib/"
    done
done
for bin in "$main"/_build/esbuild-* "$main"/_build/tailwind-*; do
    [ -e "$bin" ] && copy "$bin" _build/
done

for target in "$main"/native/*/target; do
    [ -d "$target" ] || continue
    crate=$(basename "$(dirname "$target")")
    [ -d "native/$crate" ] && [ ! -e "native/$crate/target" ] && copy "$target" "native/$crate/"
done

echo "Seeded in $(( SECONDS - start ))s"
