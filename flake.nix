{
  description = "Mydia - Self-hosted media management application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Dedicated, separately pinned nixpkgs for the Android dev shell only
    # (nix/devShells). Keeping it off the main nixpkgs means adopting that shell
    # does not re-evaluate the production package, the NixOS module or
    # nix/checks, and does not silently move the Android SDK, NDK or Flutter.
    # This is the exact rev player/flake.nix used before the shell moved here.
    nixpkgs-android.url =
      "github:NixOS/nixpkgs/567a49d1913ce81ac6e9582e3553dd90a955875f";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      # NOTE: the developer environment lives in devenv.nix (devenv.sh) with
      # per-worktree isolation, not here. The one exception is the Android dev
      # shell in ./nix/devShells: Nix is the only practical source of the
      # Android SDK/NDK, and it has to live in this flake rather than under
      # player/ so it can read the repo's rust-toolchain.toml (#252).
      imports = [
        ./nix/packages/flake-module.nix
        ./nix/checks/flake-module.nix
        ./nix/modules/flake-module.nix
        ./nix/devShells/flake-module.nix
      ];
    };
}
