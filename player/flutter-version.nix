# Resolves the Flutter package pinned by ./.fvmrc, the single source of truth for
# the Flutter version across devenv.nix, nix/devShells, the CI workflows and
# the Dockerfile. No other build or CI file may name a Flutter version, and
# ci-nix.yml's "Check / Flutter Pin" job enforces that on every pull request.
#
# `pkgs` is a parameter rather than an import so this module can be evaluated
# against a fake attrset, with no nixpkgs fetch, which is how its three outcomes
# are exercised: a matching attrset returns the package, a disagreeing
# pkg.version throws the drift error, and a missing attribute throws the
# unknown-attribute error.
{ pkgs }:

let
  version = (builtins.fromJSON (builtins.readFile ./.fvmrc)).flutter;

  # splitVersion breaks "<major>.<minor>.<patch>" into its three components. The
  # first two concatenate onto "flutter" to give nixpkgs' name for a pinned
  # Flutter minor. The patch component is deliberately dropped, because nixpkgs
  # tracks one patch per minor; the equality check below is what catches a drift.
  #
  # No illustrative version appears here on purpose. .fvmrc is the only file that
  # may name a Flutter version, and the "Check / Flutter Pin" job rejects any
  # version literal in a build or CI file, including one inside a comment.
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
