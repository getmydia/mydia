# Directories with a committed Cargo.lock that CI or the Nix build consumes.
#
# Sourced by check-generated-freshness.sh, which asserts each lock satisfies
# its manifest, and by regenerate-derived.sh, which repairs them, so the two
# cannot disagree about which locks exist. Crates without a lock of their own
# (native/mydia_p2p_core, native/mydia_plugin_sdk) are libraries resolved
# inside these.
# shellcheck shell=bash
# shellcheck disable=SC2034 # used by the scripts that source this file
cargo_lock_dirs=(
  native/mydia_p2p
  native/mydia_subsync
  plugins/webhook_notifier
  plugins/simkl_sync
  server
  player/rust/mydia_player_p2p
)
