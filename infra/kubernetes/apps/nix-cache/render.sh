#!/usr/bin/env bash
# Render niks3.yaml from niks3's upstream Helm chart at the pinned commit.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# niks3 v1.19.0, pinned to its commit (tags can move). Keep in step with the
# niks3 install in .github/actions/nix-ci/action.yml and
# scripts/nix-cache-push.sh, and with image.tag in niks3-values.yaml.
rev=3a0b84e4f909726de179b9f210e1ed1e56767b2e
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q "$tmp/niks3"
git -C "$tmp/niks3" fetch -q --depth 1 https://github.com/Mic92/niks3 "$rev"
git -C "$tmp/niks3" checkout -q FETCH_HEAD
# --no-hooks drops the chart's `helm test` Pod, which kubectl apply would
# otherwise run as a plain Pod.
helm template niks3 "$tmp/niks3/deploy/helm/niks3" --no-hooks \
  --namespace nix-cache -f "$here/niks3-values.yaml" > "$here/niks3.yaml"
