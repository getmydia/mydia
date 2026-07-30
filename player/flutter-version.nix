# Resolves the Flutter package pinned by ./.fvmrc, the single source of truth for
# the Flutter version across devenv.nix, player/flake.nix, the CI workflows and
# the Dockerfile. Nothing else in the repo may name a Flutter version.
#
# `pkgs` is a parameter rather than an import so this module can be evaluated
# against a fake attrset in tests, with no nixpkgs fetch. See the plan for the
# three nix-instantiate cases.
{ pkgs }:

let
  version = (builtins.fromJSON (builtins.readFile ./.fvmrc)).flutter;

  # splitVersion "1.2.3" -> [ "1" "2" "3" ]. The first two components join into
  # nixpkgs' name for a pinned Flutter minor: "1.2.3" becomes "flutter12". The
  # patch component is deliberately dropped, because nixpkgs tracks one patch per
  # minor; the equality check below is what catches a drift.
  #
  # The example above is deliberately not the pinned version. .fvmrc is the only
  # file in the repo that may name a Flutter version, and the check is a plain
  # grep, so an illustrative version here would fail it.
  parts = builtins.splitVersion version;
  attr = "flutter" + builtins.elemAt parts 0 + builtins.elemAt parts 1;

  pkg = pkgs.${attr} or (throw ''
    player/.fvmrc pins Flutter ${version}, but this nixpkgs has no `${attr}`.
    Either the nixpkgs pin predates that release, or nixpkgs has pruned the
    attribute. Bump the nixpkgs pin, or set .fvmrc to a version nixpkgs ships.
  '');
in
if pkg.version == version then
  pkg
else
  throw ''
    player/.fvmrc pins Flutter ${version}, but `${attr}` in this nixpkgs is
    ${pkg.version}. Set .fvmrc to ${pkg.version} and re-run `flutter pub get`,
    or hold the nixpkgs pin back.
  ''
