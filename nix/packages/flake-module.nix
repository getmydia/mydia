{ ... }:

{
  perSystem = { pkgs, system, lib, ... }:
    let
      # BEAM packages (Erlang/Elixir)
      beamPackages = pkgs.beam.packages.erlang_28;

      # Fine package (needed for lazy_html)
      fineVersion = "0.1.4";
      fineSrc = beamPackages.fetchHex {
        pkg = "fine";
        version = fineVersion;
        sha256 = "be3324cc454a42d80951cf6023b9954e9ff27c6daa255483b3e8d608670303f5";
      };

      cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
        src = ../../native/mydia_p2p;
        hash = "sha256-mwciW6cx+n26KEQYv3rJi4ceq+sKhy6rBaTMOC7/8Is=";
      };
      torrentCargoDeps = pkgs.rustPlatform.fetchCargoVendor {
        src = ../../native/mydia_torrent;
        hash = "sha256-PH/QyUa2LpNOcW65Rriv3EffBfQItyayKZOSjlVGYxY=";
      };

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
        hash = "sha256-NMEudc78qbm1x9+CV4a7z/c+YfMyUD/mYPMwfzYYoVc=";
      };

      # Tailwind CSS v4 binary (not yet in nixpkgs)
      # Needs to be patched for NixOS
      tailwindVersion = "4.1.7";
      tailwindBinaryName = {
        "x86_64-linux" = "tailwindcss-linux-x64";
        "aarch64-linux" = "tailwindcss-linux-arm64";
        "x86_64-darwin" = "tailwindcss-macos-x64";
        "aarch64-darwin" = "tailwindcss-macos-arm64";
      }.${system} or "tailwindcss-linux-x64";
      tailwindBinaryHash = {
        "x86_64-linux" = "sha256-BwYpKTWpdzxsh54X0jYlMi5EkOfo96CtDmiPquTe+YE=";
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
        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = [ pkgs.stdenv.cc.cc.lib ];
        installPhase = ''
          mkdir -p $out/bin
          cp $src $out/bin/tailwindcss
          chmod +x $out/bin/tailwindcss
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

          # Build-time dependencies
          nativeBuildInputs = [
            pkgs.nodejs
            pkgs.git
            pkgs.npmHooks.npmConfigHook
            pkgs.rustc
            pkgs.cargo
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

            # Set up Cargo vendoring for the Rust torrent NIF
            mkdir -p native/mydia_torrent/.cargo
            cat > native/mydia_torrent/.cargo/config.toml <<CARGO_EOF
            [source.crates-io]
            replace-with = "vendored-sources"

            [source.vendored-sources]
            directory = "${torrentCargoDeps}"
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
            mkdir -p _build
            ln -sf ${pkgs.esbuild}/bin/esbuild _build/esbuild-${platformSuffix}
            ln -sf ${tailwindcss_4}/bin/tailwindcss _build/tailwind-${platformSuffix}

            # Build assets (use --no-deps-check to skip lock verification for Nix-managed deps)
            export MIX_ENV=prod
            mix do compile --no-deps-check, assets.deploy
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
