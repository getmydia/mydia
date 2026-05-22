{
  description = "Mydia - Self-hosted media management application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    # devenv drives the native dev loop for the Rust workspace —
    # `./dev rs up` becomes a thin wrapper around devenv's process
    # manager, which owns `dx serve` and `tailwindcss --watch` so
    # hot reload happens against the host filesystem directly (no
    # bind-mount / inotify trickery needed).
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Required for `devenv` under flake-parts so it can resolve the
    # repo root at evaluation time. Replaced by the user's actual
    # working directory at `devenv up` / `devenv shell` time via a
    # symlink trick — see https://devenv.sh/guides/using-with-flakes/.
    devenv-root = {
      url = "file+file:///dev/null";
      flake = false;
    };
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      imports = [
        ./nix/packages/flake-module.nix
        ./nix/devShells/flake-module.nix
        ./nix/devenv/flake-module.nix
        ./nix/checks/flake-module.nix
        ./nix/modules/flake-module.nix
      ];
    };
}
