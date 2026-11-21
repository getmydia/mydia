# Mix dependency sources and their native build inputs, shared by
# nix/packages (the release, through mixRelease's mixNixDeps) and nix/ci (the
# test-env `mix deps.compile`, nix/ci/mix-deps.nix), so both build the same
# patched sources with the same vendored crates.
#
# `rustToolchain` is the caller's: the package builds Wasmex on its own
# toolchain, the CI checks on the CI one.
{ pkgs, beamPackages, rustToolchain }:

let
  # Fine package (needed for lazy_html). Keep in lockstep with mix.lock's
  # `fine` entry: lazy_html's C++ NIF build copies this source tree to
  # /build/fine-${fineVersion} so its Makefile can find fine.hpp there; a
  # stale version here silently breaks the sandbox build (the compiler
  # looks for /build/fine-<mix.lock version>/c_include/fine.hpp).
  fineVersion = "0.1.6";
  fineSrc = beamPackages.fetchHex {
    pkg = "fine";
    version = fineVersion;
    sha256 = "5638eb4495488e885ebec167fa57973e5c35e1a50c344eb7666c90ec1c4e3b12";
  };

  # Download crates from the CDN rather than the crates.io API host.
  #
  # crates.io enforces an identifying User-Agent on
  # `crates.io/api/v1/crates/<name>/<version>/download` and 403s the ones it
  # does not recognise. That is what broke `fetchCargoVendor`, and it caught
  # up with `importCargoLock`'s plain curl UA too: every `CI / Nix` run since
  # 2026-08-27 died on `cannot download crate-<name>.tar.gz from any mirror`,
  # on a different arbitrary crate each time.
  #
  # `static.crates.io` is the CDN behind the API and enforces no such policy.
  # nixpkgs made this the default in c0a89c379 (2026-05-27), which is newer
  # than the nixpkgs this flake pins, so the override is applied here. It can
  # go away when that pin moves past that commit.
  crateRegistries = {
    "https://github.com/rust-lang/crates.io-index" = "https://static.crates.io/crates";
  };

  # Wasmex is built from source, with patches/wasmex applied: the patch adds
  # the precompile-to-file and deserialize-file calls the opt-in Cardigann
  # engine needs, and lives in the Rust half of the NIF, so Wasmex's
  # precompiled NIF cannot be used. The crates come from nix/wasmex-Cargo.lock,
  # a copy of the lock the patched crate resolves (the patch adds a direct
  # `libc` dependency, which the published lock lacks). Regenerate it when
  # wasmex is bumped: copy deps/wasmex/native/wasmex/Cargo.lock after
  # `mix deps.patch` and a build.
  wasmexCargoLock = ./wasmex-Cargo.lock;
  wasmexCargoDeps = pkgs.rustPlatform.importCargoLock {
    lockFile = wasmexCargoLock;
    extraRegistries = crateRegistries;
  };

  # Run from the wasmex source root: vendors its crates (the sandbox has no
  # network) and installs the lock the patched crate resolves. WASMEX_BUILD
  # makes RustlerPrecompiled compile the NIF instead of downloading one.
  wasmexPrepare = ''
    export WASMEX_BUILD=1
    mkdir -p native/wasmex/.cargo
    cat > native/wasmex/.cargo/config.toml <<CARGO_EOF
    [source.crates-io]
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "${wasmexCargoDeps}"
    CARGO_EOF
    cp ${wasmexCargoLock} native/wasmex/Cargo.lock
    chmod u+w native/wasmex/Cargo.lock
  '';

  # Heroicons (git dependency, not an Elixir package, so mix2nix skips it).
  heroicons = pkgs.fetchFromGitHub {
    owner = "tailwindlabs";
    repo = "heroicons";
    rev = "v2.2.0";
    hash = "sha256-Jcxr1fSbmXO9bZKeg39Z/zVN0YJp17TX3LH5Us4lsZU=";
  };

  # Lexbor (needed for lazy_html NIF compilation). Its Makefile would
  # otherwise `git clone` it into _build/c/third_party/lexbor/<rev>.
  lexborRev = "244b84956a6dc7eec293781d051354f351274c46";
  lexbor = pkgs.fetchFromGitHub {
    owner = "lexbor";
    repo = "lexbor";
    rev = lexborRev;
    hash = "sha256-Oup/lGU8a9Dqfho4Llg39t9Y9n4xfUmGk0772OkpnLQ=";
  };

  # Run from the lazy_html source root.
  lexborPrepare = ''
    mkdir -p _build/c/third_party/lexbor
    cp -r ${lexbor} _build/c/third_party/lexbor/${lexborRev}
    chmod -R u+w _build/c/third_party/lexbor
  '';

  # Import Mix dependencies from deps.nix with overrides for Nix sandbox builds
  mixNixDeps = import ../deps.nix {
    lib = pkgs.lib;
    beamPackages = beamPackages;
    overrides = final: prev: {
      # lazy_html: prefetch lexbor and configure fine.hpp
      lazy_html = prev.lazy_html.override {
        nativeBuildInputs = [ pkgs.cmake pkgs.gnumake pkgs.gcc ];
        dontUseCmakeConfigure = true;

        preConfigure = lexborPrepare + ''

          cp -r ${fineSrc} /build/fine-${fineVersion}
          chmod -R u+w /build/fine-${fineVersion}
        '';

        preBuild = ''
          export HOME=/tmp
          mkdir -p /tmp/.cache/elixir_make
        '';
      };

      # exqlite: needs HOME for elixir_make cache
      exqlite = prev.exqlite.override {
        buildInputs = [ pkgs.sqlite ];
        preBuild = ''
          export HOME=/tmp
          mkdir -p /tmp/.cache/elixir_make
        '';
      };

      # argon2_elixir: needs HOME for elixir_make cache
      argon2_elixir = prev.argon2_elixir.override {
        preBuild = ''
          export HOME=/tmp
          mkdir -p /tmp/.cache/elixir_make
        '';
      };

      # bcrypt_elixir: needs HOME for elixir_make cache
      bcrypt_elixir = prev.bcrypt_elixir.override {
        preBuild = ''
          export HOME=/tmp
          mkdir -p /tmp/.cache/elixir_make
        '';
      };

      # wasmex: patched and built from source (see wasmexCargoDeps), with its
      # crates vendored because the sandbox has no network.
      wasmex = prev.wasmex.override {
        patches = [ ../patches/wasmex/component-precompile-and-deserialize.patch ];
        # Rustler decodes `cargo metadata` with Jason while compiling
        # Wasmex.Native (the precompiled path never does). Jason is only
        # Rustler's own dependency, and the offline `mix compile
        # --no-deps-check` does not resolve a dependency's dependencies, so
        # Jason would be missing from the code path. Name it directly.
        postPatch = ''
          substituteInPlace mix.exs \
            --replace-fail '{:rustler, "~> 0.38"},' '{:rustler, "~> 0.38"}, {:jason, "~> 1.0"},'
        '';
        nativeBuildInputs = [ rustToolchain ];
        preBuild = ''
          export HOME=/tmp
        '' + wasmexPrepare;
      };
    };
  };
in
{
  inherit fineVersion fineSrc crateRegistries wasmexCargoLock wasmexCargoDeps
    wasmexPrepare heroicons lexbor lexborPrepare mixNixDeps;
}
