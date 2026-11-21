{ ... }:

{
  perSystem = { pkgs, lib, self', ciPlayer, ... }: {
    # The VM tests below build both package variants, so they are not
    # repeated here as checks of their own.
    checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      # NixOS module VM tests (Linux only — requires QEMU)
      nixos-module = import ../tests/module.nix {
        inherit pkgs;
        mydiaPackage = self'.packages.default;
      };
      nixos-module-postgres = import ../tests/module-postgres.nix {
        inherit pkgs;
        mydiaPackage = self'.packages.postgres;
      };
    } // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
      # Test / Player E2E. Not `nixos-`-prefixed on purpose: scripts/ci-plan.sh
      # puts that group in ci.yml's non-blocking NixOS job, and this check is
      # a required one, so it builds in the Nix / Checks matrix.
      player-e2e = import ../tests/player-e2e.nix {
        inherit pkgs lib ciPlayer;
        mydiaPackage = self'.packages.default;
        relayPackage = self'.packages.metadata-relay;
      };
    };

    # The packages the VM tests boot, as CI planner inputs (nix/ci/README.md):
    # a build-time input of a VM test is not in its output closure, so
    # pushing the test result would never upload them.
    ciInternal = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      package-default = self'.packages.default;
      package-postgres = self'.packages.postgres;
      package-metadata-relay = self'.packages.metadata-relay;
    };
  };
}
