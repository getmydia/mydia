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
  };
}
