{ inputs, ... }:

{
  perSystem = { pkgs, system, lib, ... }:
    let
      # BEAM packages (Erlang/Elixir)
      beamPackages = pkgs.beam.packages.erlang_28;

      # Pinned Rust toolchain (rust-overlay, same construction as the dev
      # shells — pinned by flake.lock) with the wasm32-wasip2 std, so the
      # release build compiles both the p2p NIF and the bundled wasip2 plugin
      # guests under plugins/*/ (the guest's WASI world tracks the Rust
      # version; keep in lockstep with CI/Docker — see ci.yml).
      rustPkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [ inputs.rust-overlay.overlays.default ];
      };
      rustToolchain = rustPkgs.rust-bin.stable.latest.minimal.override {
        targets = [ "wasm32-wasip2" ];
      };

      # Fine package (needed for lazy_html). Keep in lockstep with mix.lock's
      # `fine` entry — lazy_html's C++ NIF build copies this source tree to
      # /build/fine-${fineVersion} so its Makefile can find fine.hpp there; a
      # stale version here silently breaks the sandbox build (the compiler
      # looks for /build/fine-<mix.lock version>/c_include/fine.hpp).
      fineVersion = "0.1.6";
      fineSrc = beamPackages.fetchHex {
        pkg = "fine";
        version = fineVersion;
        sha256 = "5638eb4495488e885ebec167fa57973e5c35e1a50c344eb7666c90ec1c4e3b12";
      };

      # Pre-fetch Rust/Cargo dependencies for the p2p NIF (required for sandbox build).
      #
      # Uses importCargoLock rather than fetchCargoVendor: fetchCargoVendor's
      # `fetch-cargo-vendor-util` downloads crates with a `python-requests/<ver>`
      # User-Agent, which crates.io now rejects with HTTP 403 (rust-lang/crates.io#13482),
      # breaking the build. importCargoLock fetches each crate via nix's fetchurl
      # (curl UA, not blocked) and derives hashes from Cargo.lock, so no vendor hash
      # to maintain. The lock is pure crates.io (no git deps), so no outputHashes needed.
      cargoDeps = pkgs.rustPlatform.importCargoLock {
        lockFile = ../../native/mydia_p2p/Cargo.lock;
      };

      # Vendored crates for the bundled webhook_notifier plugin guest, built for
      # wasm32-wasip2 by the plugins Mix compiler during `mix compile`.
      webhookNotifierCargoDeps = pkgs.rustPlatform.importCargoLock {
        lockFile = ../../plugins/webhook_notifier/Cargo.lock;
      };

      # Same for the bundled simkl_sync plugin guest. Each bundled guest is its
      # own crate with its own lock, so a new guest needs its deps vendored here
      # (and a `.cargo/config.toml` below) or the no-network sandbox build fails.
      simklSyncCargoDeps = pkgs.rustPlatform.importCargoLock {
        lockFile = ../../plugins/simkl_sync/Cargo.lock;
      };

      # Precompiled wasmex NIF (rustler_precompiled downloads this at compile
      # time, which the Nix sandbox forbids). Pre-fetch the release tarball and
      # point RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH at it so the wasmex build
      # reuses the cached artifact instead of hitting the network. Hashes come
      # from deps/wasmex/checksum-Elixir.Wasmex.Native.exs (only nif-2.15
      # artifacts are published, which is also rustler_precompiled's default).
      wasmexVersion = "0.14.0";
      wasmexNifTarget = {
        "x86_64-linux" = "x86_64-unknown-linux-gnu";
        "aarch64-linux" = "aarch64-unknown-linux-gnu";
        "x86_64-darwin" = "x86_64-apple-darwin";
        "aarch64-darwin" = "aarch64-apple-darwin";
      }.${system} or "x86_64-unknown-linux-gnu";
      wasmexNifHash = {
        "x86_64-unknown-linux-gnu" = "sha256-ubMR5fk21s+SutUv3ekcMHDgOOY8IvuBlejHH5dgU5I=";
        "aarch64-unknown-linux-gnu" = "sha256-N3HvNpmkM1F6QfxYEXAjgaRU/kF11Q/4Pbk9a9JlJ9I=";
        "x86_64-apple-darwin" = "sha256-JxOp8tgGtPW0VtbXIhfGrfVnmuWhWAFEL0btAtL1zw4=";
        "aarch64-apple-darwin" = "sha256-BFcwJT5Z1AOtytwIBpZiHUgIzO8TEqdvjCDDAymdFfg=";
      }.${wasmexNifTarget};
      wasmexNifFileName = "libwasmex-v${wasmexVersion}-nif-2.15-${wasmexNifTarget}.so.tar.gz";
      wasmexNifTarball = pkgs.fetchurl {
        url = "https://github.com/tessi/wasmex/releases/download/v${wasmexVersion}/${wasmexNifFileName}";
        hash = wasmexNifHash;
      };
      wasmexNifCache = pkgs.linkFarm "wasmex-precompiled-nif" [
        { name = wasmexNifFileName; path = wasmexNifTarball; }
      ];

      # Import Mix dependencies from deps.nix with overrides for Nix sandbox builds
      mixNixDeps = import ../../deps.nix {
        lib = pkgs.lib;
        beamPackages = beamPackages;
        overrides = final: prev: {
          # lazy_html: prefetch lexbor and configure fine.hpp
          lazy_html = prev.lazy_html.override {
            nativeBuildInputs = [ pkgs.cmake pkgs.gnumake pkgs.gcc ];
            dontUseCmakeConfigure = true;

            preConfigure = ''
              mkdir -p _build/c/third_party/lexbor
              cp -r ${lexbor} _build/c/third_party/lexbor/244b84956a6dc7eec293781d051354f351274c46
              chmod -R u+w _build/c/third_party/lexbor

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

          # wasmex: rustler_precompiled wants to download the NIF tarball at
          # compile time; serve it from a pre-fetched local cache instead.
          wasmex = prev.wasmex.override {
            preBuild = ''
              export RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=${wasmexNifCache}
            '';
          };
        };
      };

      # Heroicons (git dependency, not an Elixir package)
      heroicons = pkgs.fetchFromGitHub {
        owner = "tailwindlabs";
        repo = "heroicons";
        rev = "v2.2.0";
        hash = "sha256-Jcxr1fSbmXO9bZKeg39Z/zVN0YJp17TX3LH5Us4lsZU=";
      };

      # Lexbor (needed for lazy_html NIF compilation)
      lexbor = pkgs.fetchFromGitHub {
        owner = "lexbor";
        repo = "lexbor";
        rev = "244b84956a6dc7eec293781d051354f351274c46";
        hash = "sha256-Oup/lGU8a9Dqfho4Llg39t9Y9n4xfUmGk0772OkpnLQ=";
      };

      # Platform-specific binary names for esbuild/tailwind
      platformSuffix = {
        "x86_64-linux" = "linux-x64";
        "aarch64-linux" = "linux-arm64";
        "x86_64-darwin" = "darwin-x64";
        "aarch64-darwin" = "darwin-arm64";
      }.${system} or "linux-x64";

      # Pre-fetch npm dependencies (required for sandbox build)
      npmDeps = pkgs.fetchNpmDeps {
        src = ../../assets;
        hash = "sha256-DhOg4p37GgILp0IzzgqyoiyTBx6saHz6j4624/+Smj4=";
      };

      # Tailwind CSS v4 binary (not yet in nixpkgs)
      # Needs to be patched for NixOS
      tailwindVersion = "4.3.3";
      tailwindBinaryName = {
        "x86_64-linux" = "tailwindcss-linux-x64";
        "aarch64-linux" = "tailwindcss-linux-arm64";
        "x86_64-darwin" = "tailwindcss-macos-x64";
        "aarch64-darwin" = "tailwindcss-macos-arm64";
      }.${system} or "tailwindcss-linux-x64";
      tailwindBinaryHash = {
        "x86_64-linux" = "sha256-c3vs+NStERXqmN9p+pQCbUAsqP65EwagNbWwBBZ9qN0=";
        "aarch64-linux" = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        "x86_64-darwin" = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        "aarch64-darwin" = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      }.${system} or "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      tailwindcss_4_src = pkgs.fetchurl {
        url = "https://github.com/tailwindlabs/tailwindcss/releases/download/v${tailwindVersion}/${tailwindBinaryName}";
        hash = tailwindBinaryHash;
      };
      # Patch the binary for NixOS (fix interpreter and library paths)
      tailwindcss_4 = pkgs.stdenv.mkDerivation {
        pname = "tailwindcss";
        version = tailwindVersion;
        src = tailwindcss_4_src;
        dontUnpack = true;
        # Tailwind v4's standalone binary is a bun single-file executable: the Bun
        # runtime with the JS payload appended past the ELF sections. stdenv's
        # default fixupPhase strip discards that payload, leaving a binary that
        # runs as bare Bun and silently emits an EMPTY stylesheet — the package
        # builds fine and the app boots with no CSS at all. Never strip it.
        dontStrip = true;
        nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.makeWrapper ];
        buildInputs = [ pkgs.stdenv.cc.cc.lib ];
        installPhase = ''
          mkdir -p $out/bin
          cp $src $out/bin/tailwindcss
          chmod +x $out/bin/tailwindcss
        '';
        # bun unpacks the bundled @parcel/watcher native addon to /$bunfs/root/
        # at RUNTIME, so autoPatchelfHook cannot reach it — it does not exist at
        # build time. Without libstdc++ on the loader path the addon fails with
        # ERR_DLOPEN_FAILED. Wrap rather than patch.
        postFixup = ''
          wrapProgram $out/bin/tailwindcss \
            --prefix LD_LIBRARY_PATH : ${pkgs.stdenv.cc.cc.lib}/lib
        '';
      };

      # Extract default version from mix.exs version() function
      version = let
        content = builtins.readFile ../../mix.exs;
        singleLine = builtins.replaceStrings ["\n"] [" "] content;
        # Match the fallback: nil -> "0.0.0-dev"
        matched = builtins.match ''.*nil -> "([0-9]+[.][0-9]+[.][0-9]+[^"]*)".*'' singleLine;
      in if matched != null then builtins.head matched else "0.0.0-dev";

      # Parameterized builder for Mydia variants (SQLite default, PostgreSQL)
      mkMydia = { databaseType ? null, extraBuildInputs ? [], extraRuntimeDeps ? [] }:
        beamPackages.mixRelease ({
          pname = "mydia" + (if databaseType == "postgres" then "-postgres" else "");
          inherit version;
          src = ../..;

          mixNixDeps = mixNixDeps;

          # Build-time dependencies. rustToolchain (not pkgs.rustc/cargo)
          # carries the wasm32-wasip2 std for the bundled plugin guests.
          nativeBuildInputs = [
            pkgs.nodejs
            pkgs.git
            pkgs.npmHooks.npmConfigHook
            rustToolchain
          ];

          # Runtime dependencies for NIFs
          buildInputs = [
            pkgs.sqlite
            pkgs.ffmpeg_6-headless
          ] ++ extraBuildInputs;

          # Don't strip symbols (needed for Erlang NIFs)
          dontStrip = true;

          # Set HOME to a writable directory for elixir_make cache
          HOME = "/tmp";

          # Remove dev/test dependencies from the build
          removeCookie = false;

          # Pre-fetched npm dependencies
          inherit npmDeps;
          npmRoot = "assets";

          # Create missing deps symlinks and set up Cargo vendoring for Rust NIF
          postConfigure = ''
            echo "=== postConfigure: Creating missing deps symlinks ==="

            # Create deps symlinks for packages linked in _build/prod/lib
            # but missing from deps/ (e.g., buildRebar3 packages like hackney, luerl)
            for lib_dir in _build/prod/lib/*; do
              dep_name=$(basename "$lib_dir")
              if [ ! -e "deps/$dep_name" ]; then
                # Follow the symlink to get the actual nix store path
                real_lib=$(readlink -f "$lib_dir")
                # Link to the full app directory (not just /src) so Mix can find .app files
                echo "  Creating symlink: deps/$dep_name -> $real_lib"
                ln -s "$real_lib" "deps/$dep_name"
              fi
            done

            echo "=== postConfigure: Done. deps/ count ==="
            ls deps/ | wc -l

            # Set up Cargo vendoring for the Rust p2p NIF
            mkdir -p native/mydia_p2p/.cargo
            cat > native/mydia_p2p/.cargo/config.toml <<CARGO_EOF
            [source.crates-io]
            replace-with = "vendored-sources"

            [source.vendored-sources]
            directory = "${cargoDeps}"
            CARGO_EOF

            # Same for the bundled webhook_notifier plugin guest (wasm32-wasip2),
            # compiled by the plugins Mix compiler during `mix compile`.
            mkdir -p plugins/webhook_notifier/.cargo
            cat > plugins/webhook_notifier/.cargo/config.toml <<CARGO_EOF
            [source.crates-io]
            replace-with = "vendored-sources"

            [source.vendored-sources]
            directory = "${webhookNotifierCargoDeps}"
            CARGO_EOF

            # Same for the bundled simkl_sync plugin guest.
            mkdir -p plugins/simkl_sync/.cargo
            cat > plugins/simkl_sync/.cargo/config.toml <<CARGO_EOF
            [source.crates-io]
            replace-with = "vendored-sources"

            [source.vendored-sources]
            directory = "${simklSyncCargoDeps}"
            CARGO_EOF
          '';

          # Configure asset compilation
          preBuild = ''
            # Copy heroicons to deps (git dependency, not handled by mixNixDeps)
            mkdir -p deps/heroicons
            cp -r ${heroicons}/optimized deps/heroicons/

            # Install npm dependencies from cache (npmConfigHook sets up the cache)
            cd assets
            npm ci --ignore-scripts
            cd ..

            # Link platform-specific binaries for esbuild and tailwind
            # Use tailwindcss v4 binary (patched for NixOS)
            # The tailwind mix installer (>= 0.5) embeds the configured
            # version in the expected binary path (tailwind-<target>-<version>),
            # so the symlink name must include it or install_and_run/2 thinks
            # the binary is missing and tries to fetch it over the network,
            # which fails in the sandboxed build.
            mkdir -p _build
            ln -sf ${pkgs.esbuild}/bin/esbuild _build/esbuild-${platformSuffix}
            ln -sf ${tailwindcss_4}/bin/tailwindcss _build/tailwind-${platformSuffix}-${tailwindVersion}

            # Build assets (use --no-deps-check to skip lock verification for Nix-managed deps)
            export MIX_ENV=prod
            mix do compile --no-deps-check, assets.deploy

            # Same guard as the Docker builders: a bundled plugin manifest must
            # have its compiled wasm artifact, or the package ships a plugin
            # that can never load.
            for m in priv/plugins/*.json; do
              w="priv/plugins/$(basename "$m" .json).wasm"
              if [ ! -f "$w" ]; then
                echo "ERROR: missing bundled plugin artifact: $w" >&2
                exit 1
              fi
            done
          '';

          # MIX_ENV is set by mixRelease automatically

          # Post-install: wrap the release binary to include runtime deps
          postInstall = ''
            wrapProgram $out/bin/mydia \
              --prefix PATH : ${pkgs.lib.makeBinPath (
                [ pkgs.ffmpeg_6-headless pkgs.sqlite pkgs.openssl ] ++ extraRuntimeDeps
              )}
          '';
        } // pkgs.lib.optionalAttrs (databaseType != null) {
          DATABASE_TYPE = databaseType;
        });

      # SQLite variant (default)
      mydia = mkMydia {};

      # PostgreSQL variant
      mydia-postgres = mkMydia {
        databaseType = "postgres";
        extraBuildInputs = [ pkgs.postgresql ];
        extraRuntimeDeps = [ pkgs.postgresql ];
      };

    in
    {
      packages = {
        default = mydia;
        postgres = mydia-postgres;
      };
    };
}
