# Nix-native CI: checks as derivations. See nix/ci/README.md.
#
# This module owns the shared pieces (source file sets, toolchains, the
# crane lib) and the outputs the per-check files add to:
#
#   legacyPackages.<system>.ciInternal   internal derivations (dependency
#                                        builds, NIFs, plugin wasm), built
#                                        with `nix build .#ciInternal.<name>`
#   legacyPackages.<system>.ciRustAttrs  list of Rust check attribute names
#   legacyPackages.<system>.ciAndroid    Build / Android's dev shell and
#                                        stamp (nix/ci/android.nix)
#
# The per-check files set the perSystem options `ciChecks`, `ciInternal` and
# `ciRustAttrs`, which merge across modules (legacyPackages itself does not).
#
# All of it is Linux only. The checks copy their build from /build/source,
# the Linux sandbox's build directory, and CI runs on x86_64-linux, so on
# the flake's Darwin systems `checks` holds none of them and the two
# legacyPackages entries are absent, as for the NixOS tests in
# nix/checks/flake-module.nix.
{ inputs, lib, flake-parts-lib, ... }:

{
  imports = [ ./rust.nix ./mix-deps.nix ./elixir.nix ./tests.nix ./relay.nix ./guards.nix ./player.nix ./android.nix ];

  options.perSystem = flake-parts-lib.mkPerSystemOption {
    options = {
      ciChecks = lib.mkOption {
        type = lib.types.lazyAttrsOf lib.types.package;
        default = { };
        description = "CI checks, exposed as checks on Linux systems.";
      };
      ciInternal = lib.mkOption {
        type = lib.types.lazyAttrsOf lib.types.package;
        default = { };
        description = "Internal CI derivations, exposed as legacyPackages.ciInternal.";
      };
      ciAndroid = lib.mkOption {
        type = lib.types.lazyAttrsOf lib.types.package;
        default = { };
        description = "Build / Android's dev shell and stamp (nix/ci/android.nix), exposed as legacyPackages.ciAndroid.";
      };
      ciRustAttrs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Names of the Rust checks, exposed as legacyPackages.ciRustAttrs.";
      };
    };
  };

  config.perSystem = { pkgs, system, config, ciElixir, ... }:
    let
      toolchains = import ../toolchains.nix { inherit inputs pkgs system; };
      inherit (toolchains) beamPackages;

      # The CI toolchain: the rust-toolchain.toml version with fmt and clippy
      # (nix/toolchains.nix `rustToolchainCi`). The package keeps its own
      # `rustToolchain`; nothing under nix/ci uses that one.
      rustToolchain = toolchains.rustToolchainCi;

      root = ../..;
      sources = import ./sources.nix { inherit lib root; };

      craneLib = (inputs.crane.mkLib pkgs).overrideToolchain rustToolchain;

      # Directories whose tracked files must belong to a source file set.
      codeDirs = [ "lib" "config" "priv" "test" "native" "plugins" "server" "metadata-relay" "player" ];

      tracked = lib.fileset.intersection
        (lib.fileset.gitTracked root)
        (lib.fileset.unions (map (d: root + "/${d}") codeDirs));

      uncovered = lib.filter (p: !(lib.hasSuffix ".md" p))
        (map (p: lib.removePrefix "${toString root}/" (toString p))
          (lib.fileset.toList (lib.fileset.difference tracked sources.all)));
    in
    {
      _module.args.ci = { inherit sources rustToolchain beamPackages craneLib; };

      checks = lib.mkIf pkgs.stdenv.hostPlatform.isLinux config.ciChecks;

      legacyPackages = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
        inherit (config) ciInternal ciRustAttrs ciAndroid;
      };

      # The shell of the CI jobs that stay outside the sandbox: `Lint /
      # Ratchet`, which reads git history, and `Rust / SMB integration`,
      # which needs a root smbd. The checks' BEAM pair and Rust toolchain,
      # and the checks' Mix environment (MIX_ENV=test, Hex offline from the
      # store, MYDIA_PREBUILT_NIFS/PLUGINS), so Mix accepts a copy of
      # ciInternal.mydiaTestBuild-sqlite as up to date. See
      # scripts/ci-restore-test-build.sh.
      devShells.ci = pkgs.mkShell {
        packages = [
          beamPackages.erlang
          beamPackages.elixir
          rustToolchain
          pkgs.git
        ];
        env = ciElixir.env;
      };

      ciChecks.ci-fileset-coverage = pkgs.runCommand "ci-fileset-coverage"
        {
          uncovered = lib.concatLines uncovered;
          # Too large for the environment when nothing is covered.
          passAsFile = [ "uncovered" ];
        }
        ''
          if [ -s "$uncoveredPath" ]; then
            echo "Tracked files not covered by any set in nix/ci/sources.nix:" >&2
            sed 's/^/  /' "$uncoveredPath" >&2
            echo "Add them to a file set (or to the *.md allowlist rule)." >&2
            exit 1
          fi
          touch $out
        '';
    };
}
