# Nix-native CI: checks as derivations. See nix/ci/README.md.
#
# This module owns the shared pieces (source file sets, toolchains, the
# crane lib) and the outputs the per-check files add to:
#
#   legacyPackages.<system>.ciInternal   internal derivations (dependency
#                                        builds, NIFs, plugin wasm), built
#                                        with `nix build .#ciInternal.<name>`
#   legacyPackages.<system>.ciRustAttrs  list of Rust check attribute names
{ inputs, lib, ... }:

{
  perSystem = { pkgs, system, config, ... }:
    let
      toolchains = import ../toolchains.nix { inherit inputs pkgs system; };
      inherit (toolchains) beamPackages rustToolchain;

      root = ../..;
      sources = import ./sources.nix { inherit lib root; };

      craneLib = (inputs.crane.mkLib pkgs).overrideToolchain rustToolchain;

      # Directories whose tracked files must belong to a source file set.
      codeDirs = [ "lib" "config" "priv" "test" "native" "plugins" "server" "metadata-relay" ];

      tracked = lib.fileset.intersection
        (lib.fileset.gitTracked root)
        (lib.fileset.unions (map (d: root + "/${d}") codeDirs));

      uncovered = lib.filter (p: !(lib.hasSuffix ".md" p))
        (map (p: lib.removePrefix "${toString root}/" (toString p))
          (lib.fileset.toList (lib.fileset.difference tracked sources.all)));
    in
    {
      _module.args.ci = { inherit sources rustToolchain beamPackages craneLib; };

      legacyPackages = {
        ciInternal = { };
        ciRustAttrs = [ ];
      };

      checks.ci-fileset-coverage = pkgs.runCommand "ci-fileset-coverage"
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
