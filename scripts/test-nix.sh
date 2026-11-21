#!/usr/bin/env bash
# Run Nix package and NixOS module tests.
#
# Usage:
#   ./scripts/test-nix.sh          # run all checks
#   ./scripts/test-nix.sh all      # run all checks
#   ./scripts/test-nix.sh package  # build the package only
#   ./scripts/test-nix.sh module   # run the NixOS VM test only

set -euo pipefail

SYSTEM=$(nix eval --impure --raw --expr 'builtins.currentSystem')

run_all() {
  echo "Running all Nix checks for ${SYSTEM}..."
  nix flake check -L
}

run_package() {
  echo "Building package for ${SYSTEM}..."
  nix build -L ".#packages.${SYSTEM}.default"
}

run_module() {
  if [[ "$SYSTEM" != *-linux ]]; then
    echo "Error: NixOS module test requires Linux (current system: ${SYSTEM})"
    exit 1
  fi
  echo "Running NixOS module VM test for ${SYSTEM}..."
  nix build -L ".#checks.${SYSTEM}.nixos-module"
}

case "${1:-all}" in
  all)     run_all ;;
  package) run_package ;;
  module)  run_module ;;
  *)
    echo "Usage: $0 [all|package|module]"
    exit 1
    ;;
esac
