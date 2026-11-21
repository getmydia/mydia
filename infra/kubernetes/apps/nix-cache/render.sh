#!/usr/bin/env bash
# Render niks3.yaml from niks3's upstream Helm chart at the pinned tag.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tag=v1.19.0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 --branch "$tag" https://github.com/Mic92/niks3 "$tmp/niks3"
# --no-hooks drops the chart's `helm test` Pod, which kubectl apply would
# otherwise run as a plain Pod.
helm template niks3 "$tmp/niks3/deploy/helm/niks3" --no-hooks \
  --namespace nix-cache -f "$here/niks3-values.yaml" > "$here/niks3.yaml"
