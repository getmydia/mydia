# Resolves the Elixir/OTP pair pinned by ./.elixir-version and ./.otp-version,
# the single sources of truth for the Elixir minor and the OTP major across
# devenv.nix, nix/packages/flake-module.nix and the Dockerfile. ci-nix.yml's
# "Check / BEAM Pin" job (scripts/check-beam-pin.sh) enforces that no other
# build or CI file names either one.
#
# The minor and the major, not the patches: nixpkgs ships one patch per
# attribute, and devenv.lock and flake.lock may resolve different patches of
# the same pair without consequence. What must not drift is the Elixir minor,
# where the type system and the hard deprecations live, and the OTP major,
# where the NIF ABI and OTP's own removals live. The Dockerfile names exact
# patches in its base tag, because only it builds against musl.
#
# Returns { beam, elixir, erlang }, all drawn from one beam package set so the
# pair on PATH can never mismatch: `beam` for consumers that need the whole
# set (mixRelease, buildMix, rebar3), `elixir` and `erlang` for the dev shell.
#
# `pkgs` is a parameter rather than an import so this module can be evaluated
# against a fake attrset with no nixpkgs fetch, which is how its failure modes
# are exercised.
{ pkgs }:

let
  readPin = file: builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile file);

  elixirVersion = readPin ./.elixir-version;
  otpVersion = readPin ./.otp-version;

  parts = builtins.splitVersion elixirVersion;
  elixirAttr = "elixir_" + builtins.elemAt parts 0 + "_" + builtins.elemAt parts 1;
  otpAttr = "erlang_" + otpVersion;

  beam = pkgs.beam.packages.${otpAttr} or (throw ''
    .otp-version pins OTP ${otpVersion}, but this nixpkgs has no
    `beam.packages.${otpAttr}`. Either the nixpkgs pin predates that
    release, or nixpkgs has pruned the attribute. Update the lock, or set
    .otp-version to a major nixpkgs ships.
  '');

  elixir = beam.${elixirAttr} or (throw ''
    .elixir-version pins Elixir ${elixirVersion}, but this nixpkgs has no
    `beam.packages.${otpAttr}.${elixirAttr}`. Either the nixpkgs pin predates
    that release, or nixpkgs has pruned the attribute. Update the lock, or set
    .elixir-version to a minor nixpkgs ships.
  '');
in
{
  inherit beam elixir;
  erlang = beam.erlang;
}
