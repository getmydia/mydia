# The fetchNpmDeps hashes in nix/packages/flake-module.nix: compute, read and
# write them.
#
# Sourced by check-generated-freshness.sh (compares computed with pinned),
# update-npm-deps-hash.sh (the pre-commit hook) and regenerate-derived.sh, so
# all three agree on how each hash is computed and where it lives.
#
# The hash is computed, never checked by building `.#...npmDeps`. That
# derivation is fixed-output, so its store path depends only on the declared
# hash: an unbumped hash names the same path master already built, a binary
# cache substitutes it, nothing is fetched and the build "passes". That is how
# #967 merged green and broke master's `CI / Nix`.
#
# Run from the repository root. Needs nix on PATH.
# shellcheck shell=bash

npm_deps_flake_module=nix/packages/flake-module.nix

# One entry per fetchNpmDeps block, as "<lockfile> <binding>": the lockfile
# the block hashes and the Nix binding it is assigned to. Every function below
# takes one entry's fields. Dependabot bumps both lockfiles (the /assets and
# /metadata-relay/assets entries in .github/dependabot.yml).
npm_deps_targets=(
  "assets/package-lock.json npmDeps"
  "metadata-relay/assets/package-lock.json relayNpmDeps"
)

# The hash of a lockfile as fetchNpmDeps computes it.
# prefetch-npm-deps comes from this flake's pinned nixpkgs (--inputs-from .),
# the same version fetchNpmDeps uses, so the two cannot disagree. It downloads
# every tarball, so registry hiccups are retried.
npm_deps_hash() {
  local lockfile="$1" attempts=3 i out
  for ((i = 1; i <= attempts; i++)); do
    if out="$(nix run --inputs-from . nixpkgs#prefetch-npm-deps -- "$lockfile" | tail -n 1)"; then
      case "$out" in
        sha256-*)
          echo "$out"
          return 0
          ;;
      esac
      echo "prefetch-npm-deps printed '$out' for $lockfile, which is not a hash" >&2
      return 1
    fi
    if [ "$i" -lt "$attempts" ]; then
      echo "note: prefetch-npm-deps failed on $lockfile (attempt $i/$attempts), retrying..." >&2
      sleep "$((i * 10))"
    fi
  done
  return 1
}

# The sed address of a binding's fetchNpmDeps block. Anchored on the start of
# the line (leading whitespace only), so `npmDeps` cannot match inside
# `relayNpmDeps` or the reverse.
_npm_deps_block() {
  printf '/^[[:space:]]*%s = pkgs\\.fetchNpmDeps \\{/,/\\};/' "$1"
}

# The hash currently pinned in a binding's fetchNpmDeps block.
npm_deps_hash_pinned() {
  sed -n -E "$(_npm_deps_block "$1") s|.*hash = \"(sha256-[^\"]+)\";.*|\\1|p" \
    "$npm_deps_flake_module"
}

# Pin a new hash for a binding. Scoped to its fetchNpmDeps block so no other
# `hash =` in the file can match.
npm_deps_hash_write() {
  sed -i -E "$(_npm_deps_block "$1") s|hash = \"sha256-[^\"]+\";|hash = \"$2\";|" \
    "$npm_deps_flake_module"
}
