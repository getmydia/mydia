# npmDeps.hash in nix/packages/flake-module.nix: compute, read and write it.
#
# Sourced by check-generated-freshness.sh (compares computed with pinned),
# update-npm-deps-hash.sh (the pre-commit hook) and regenerate-derived.sh, so
# all three agree on how the hash is computed and where it lives.
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
npm_deps_lockfile=assets/package-lock.json

# The hash of assets/package-lock.json as fetchNpmDeps computes it.
# prefetch-npm-deps comes from this flake's pinned nixpkgs (--inputs-from .),
# the same version fetchNpmDeps uses, so the two cannot disagree. It downloads
# every tarball, so registry hiccups are retried.
npm_deps_hash() {
  local attempts=3 i out
  for ((i = 1; i <= attempts; i++)); do
    if out="$(nix run --inputs-from . nixpkgs#prefetch-npm-deps -- "$npm_deps_lockfile" | tail -n 1)"; then
      case "$out" in
        sha256-*)
          echo "$out"
          return 0
          ;;
      esac
      echo "prefetch-npm-deps printed '$out', which is not a hash" >&2
      return 1
    fi
    if [ "$i" -lt "$attempts" ]; then
      echo "note: prefetch-npm-deps failed (attempt $i/$attempts), retrying..." >&2
      sleep "$((i * 10))"
    fi
  done
  return 1
}

# The hash currently pinned in the fetchNpmDeps block.
npm_deps_hash_pinned() {
  sed -n -E '/npmDeps = pkgs\.fetchNpmDeps \{/,/\};/ s|.*hash = "(sha256-[^"]+)";.*|\1|p' \
    "$npm_deps_flake_module"
}

# Pin a new hash. Scoped to the fetchNpmDeps block so no other `hash =` in the
# file can match.
npm_deps_hash_write() {
  sed -i -E "/npmDeps = pkgs\.fetchNpmDeps \{/,/\};/ s|hash = \"sha256-[^\"]+\";|hash = \"$1\";|" \
    "$npm_deps_flake_module"
}
