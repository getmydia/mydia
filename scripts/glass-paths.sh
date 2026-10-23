# Paths whose staged content changes how Liquid Glass renders. Sourced by
# check-glass-diff.sh and glass-diff.sh. This is the only copy of the list:
# the `glass-diff` hook in devenv.nix runs on every commit.

# shellcheck disable=SC2034  # used by the scripts that source this file
GLASS_PATHS=(
  player/shaders/liquid_glass.frag
  player/lib/core/theme/liquid_glass
  player/lib/core/theme/depth_tokens.dart
  player/lib/presentation/widgets/glass
  player/lib/presentation/widgets/glass_surface.dart
  player/tool/liquid_glass_lab
)

# The key for the staged glass content: a hash of the index entries (mode,
# blob, path) under GLASS_PATHS. Any staged change to those files changes it.
glass_stamp() {
  git -C "$1" ls-files -s -- "${GLASS_PATHS[@]}" | sha256sum | cut -c1-16
}
