# Resolves the Elixir package pinned by ./.elixir-version, the single source of
# truth for the Elixir minor across devenv.nix, nix/packages/flake-module.nix
# and the Dockerfile. ci-nix.yml's "Check / Elixir Pin" job enforces that no
# other build or CI file names an Elixir version.
#
# The minor, not the patch: nixpkgs ships one patch per minor attribute, and
# devenv.lock and flake.lock resolve to different patches of the same minor
# without consequence. What must not drift is the minor, because that is where
# the type system and the hard deprecations live.
#
# `pkgs` is a parameter rather than an import so this module can be evaluated
# against a fake attrset with no nixpkgs fetch, which is how its two failure
# modes are exercised.
{ pkgs }:

let
  version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ./.elixir-version);

  parts = builtins.splitVersion version;
  attr = "elixir_" + builtins.elemAt parts 0 + "_" + builtins.elemAt parts 1;

  # OTP is pinned separately and deliberately: erlang_28 across every path.
  beam = pkgs.beam.packages.erlang_28;
in
beam.${attr} or (throw ''
  .elixir-version pins Elixir ${version}, but this nixpkgs has no
  `beam.packages.erlang_28.${attr}`. Either the nixpkgs pin predates that
  release, or nixpkgs has pruned the attribute. Update the lock, or set
  .elixir-version to a minor nixpkgs ships.
'')
