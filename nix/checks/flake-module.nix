{ ... }:

{
  perSystem = { pkgs, self', ... }: {
    # The VM tests below build both package variants, so they are not
    # repeated here as checks of their own.
    checks = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
      # NixOS module VM tests (Linux only — requires QEMU)
      nixos-module = import ../tests/module.nix {
        inherit pkgs;
        mydiaPackage = self'.packages.default;
      };
      nixos-module-postgres = import ../tests/module-postgres.nix {
        inherit pkgs;
        mydiaPackage = self'.packages.postgres;
      };
    };

    # The packages the VM tests boot, as CI planner inputs (nix/ci/README.md):
    # a build-time input of a VM test is not in its output closure, so
    # pushing the test result would never upload them.
    ciInternal = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
      package-default = self'.packages.default;
      package-postgres = self'.packages.postgres;
    };
  };
}
