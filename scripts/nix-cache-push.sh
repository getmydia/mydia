#!/usr/bin/env bash
# Build flake outputs locally and push them to the CI binary cache
# (niks3 at niks3.mydia.dev, read side cache.mydia.dev), so CI finds them
# already built.
#
# Usage:
#   scripts/nix-cache-push.sh [--rev <commit>] [--mode builds|all] [<attr>...]
#
#   --rev   build that commit (git+file:<repo>?rev=<commit>) instead of the
#           working tree. The pre-push hook passes the commit being pushed.
#   --mode  builds (default): every ciInternal output, the expensive compile
#           artifacts. all: every check too, which runs the test suites.
#   <attr>  explicit attributes, e.g. checks.x86_64-linux.rust-mydia_subsync-test
#
# Needs the niks3 admin token in ${XDG_CONFIG_HOME:-$HOME/.config}/mydia/niks3-token:
#   kubectl --context k3s-can1 -n nix-cache get secret niks3-token \
#     -o jsonpath='{.data.token}' | base64 -d > ~/.config/mydia/niks3-token
#
# Derivation hashes depend only on inputs, so a path built from a commit is
# exactly the path CI looks up for that content.
set -euo pipefail

system=x86_64-linux
token="${NIKS3_TOKEN_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/mydia/niks3-token}"
server="${NIKS3_URL:-https://niks3.mydia.dev}"
# niks3 v1.19.0, pinned to its commit (tags can move).
niks3=(nix run github:Mic92/niks3/3a0b84e4f909726de179b9f210e1ed1e56767b2e --)
substituter_opts=(
  --option extra-substituters https://cache.mydia.dev
  --option extra-trusted-public-keys 'cache.mydia.dev-1:5zkoQR4Gcrx1EEQ1GvHRPQ7EoHm8gNrrVoeAqX3ioFg='
)

flake=.
mode=builds
attrs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rev) flake="git+file:$(git rev-parse --show-toplevel)?rev=$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    *) attrs+=("$1"); shift ;;
  esac
done

if [ ! -r "$token" ]; then
  echo "error: no niks3 token at $token (see the header of $0)" >&2
  exit 1
fi

names() {
  # $1: attribute path of an attrset; prints "<path>.<name>" per member.
  nix eval --json "$flake#$1" --apply builtins.attrNames 2>/dev/null \
    | jq -r --arg p "$1" '.[] | "\($p).\(.)"'
}

if [ "${#attrs[@]}" -eq 0 ]; then
  case "$mode" in
    builds) mapfile -t attrs < <(names "legacyPackages.$system.ciInternal") ;;
    all) mapfile -t attrs < <(names "legacyPackages.$system.ciInternal"; names "checks.$system") ;;
    *) echo "error: --mode must be builds or all" >&2; exit 1 ;;
  esac
fi

if [ "${#attrs[@]}" -eq 0 ]; then
  echo "nothing to build"
  exit 0
fi

# One attribute at a time, so a failing check does not stop the rest from
# being built and pushed.
paths=()
for attr in "${attrs[@]}"; do
  if out=$(nix build --no-link --print-out-paths "${substituter_opts[@]}" "$flake#$attr"); then
    paths+=($out)
  else
    echo "warning: $attr failed to build, skipping" >&2
  fi
done

if [ "${#paths[@]}" -eq 0 ]; then
  echo "error: nothing built" >&2
  exit 1
fi

"${niks3[@]}" push --server-url "$server" --auth-token-path "$token" "${paths[@]}"
