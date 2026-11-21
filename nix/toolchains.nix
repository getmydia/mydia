# Toolchains shared by nix/packages and nix/ci, so both build on one definition.
{ inputs, pkgs, system }:

let
  # BEAM packages (Erlang/Elixir). The OTP major and the Elixir minor come
  # from .otp-version and .elixir-version through beam-version.nix, the
  # same source devenv.nix imports and the Dockerfile is checked against.
  # Overriding `elixir` in the set makes mixRelease and every buildMix dep
  # in deps.nix compile on it, rather than on whatever patch nixpkgs
  # happens to default this set to.
  #
  # `overrideScope`, not `.extend`: this nixpkgs pin has already removed
  # `.extend` from beamPackages in favor of `.overrideScope` (it throws
  # "'beamPackages.extend' has been replaced by 'beamPackages.overrideScope'"
  # when evaluated, even though `? extend` reports the attribute present).
  beamPin = import ../beam-version.nix { inherit pkgs; };
  beamPackages = beamPin.beam.overrideScope (_final: _prev: {
    elixir = beamPin.elixir;
  });

  # Pinned Rust toolchain (rust-overlay, same construction as the dev
  # shells, pinned by flake.lock) with the wasm32-wasip2 std, so the
  # release build compiles both the p2p NIF and the bundled wasip2 plugin
  # guests under plugins/*/ (the guest's WASI world tracks the Rust
  # version; keep in lockstep with CI/Docker, see ci.yml).
  rustPkgs = import inputs.nixpkgs {
    inherit system;
    overlays = [ inputs.rust-overlay.overlays.default ];
  };
  rustToolchain = rustPkgs.rust-bin.stable.latest.minimal.override {
    targets = [ "wasm32-wasip2" ];
  };

  # The CI checks' toolchain: the version rust-toolchain.toml pins (the one
  # devenv, and so the pre-commit hooks and the old CI jobs, used), with fmt
  # and clippy, and wasm32-unknown-unknown for the p2p core's browser build.
  # Never name a Rust version here; the channel is read from the file.
  rustChannel =
    (builtins.fromTOML (builtins.readFile ../rust-toolchain.toml)).toolchain.channel;
  rustToolchainCi = rustPkgs.rust-bin.stable.${rustChannel}.minimal.override {
    extensions = [ "clippy" "rustfmt" ];
    targets = [ "wasm32-wasip2" "wasm32-unknown-unknown" ];
  };
in
{ inherit beamPin beamPackages rustToolchain rustToolchainCi; }
