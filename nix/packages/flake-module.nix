{ inputs, ... }:

{
  perSystem = { pkgs, system, lib, ... }:
    let
      # beamPackages (pinned Elixir/OTP) and rustToolchain (rust-overlay with
      # the wasm32-wasip2 std). Defined in nix/toolchains.nix, shared with
      # nix/ci so the CI checks build on the same pins as the package.
      inherit (import ../toolchains.nix { inherit inputs pkgs system; })
        beamPackages rustToolchain;

      # Mix dependencies from deps.nix with their sandbox overrides (lazy_html,
      # exqlite, argon2/bcrypt, the patched Wasmex), heroicons, and the crates.io
      # CDN mapping. Defined in nix/beam-deps.nix, shared with nix/ci so the
      # test-env dependency build uses the same sources.
      inherit (import ../beam-deps.nix { inherit pkgs beamPackages rustToolchain; })
        crateRegistries mixNixDeps heroicons;

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
        extraRegistries = crateRegistries;
      };

      # Vendored crates for the bundled webhook_notifier plugin guest, built for
      # wasm32-wasip2 by the plugins Mix compiler during `mix compile`.
      webhookNotifierCargoDeps = pkgs.rustPlatform.importCargoLock {
        lockFile = ../../plugins/webhook_notifier/Cargo.lock;
        extraRegistries = crateRegistries;
      };

      # Same for the bundled simkl_sync plugin guest. Each bundled guest is its
      # own crate with its own lock, so a new guest needs its deps vendored here
      # (and a `.cargo/config.toml` below) or the no-network sandbox build fails.
      simklSyncCargoDeps = pkgs.rustPlatform.importCargoLock {
        lockFile = ../../plugins/simkl_sync/Cargo.lock;
        extraRegistries = crateRegistries;
      };

      # Vendored crates for the bundled plex plugin guest. Each guest is its
      # own crate with its own lock, so it needs this binding and the
      # `.cargo/config.toml` written in postConfigure, or the no-network sandbox
      # build dies after `[plugins] compiling plex` without printing an error.
      plexCargoDeps = pkgs.rustPlatform.importCargoLock {
        lockFile = ../../plugins/plex/Cargo.lock;
        extraRegistries = crateRegistries;
      };

      # Vendored crates for the subtitle re-sync NIF. Like the p2p NIF above,
      # this is its own crate with its own lock, so it needs both this binding
      # and a `.cargo/config.toml` in postConfigure or the no-network sandbox
      # build fails without printing an error.
      subsyncCargoDeps = pkgs.rustPlatform.importCargoLock {
        lockFile = ../../native/mydia_subsync/Cargo.lock;
        extraRegistries = crateRegistries;
      };

      # Platform-specific binary names for esbuild/tailwind.
      #
      # Throws rather than falling back. The previous `or "linux-x64"` was
      # silently wrong on any unlisted system, in three separate ways: it named
      # the Tailwind fetchurl (collapsing its version-qualified name back onto
      # the x86_64 one, defeating the stale-hash guard below), and it named the
      # _build/esbuild-* and _build/tailwind-* symlinks that the Elixir esbuild
      # and tailwind wrappers look for. A mismatched symlink makes those
      # wrappers try to download the binary at build time, which fails in the
      # sandbox for reasons that point nowhere near this table.
      platformSuffix = {
        "x86_64-linux" = "linux-x64";
        "aarch64-linux" = "linux-arm64";
        "x86_64-darwin" = "darwin-x64";
        "aarch64-darwin" = "darwin-arm64";
      }.${system} or (throw
        "mydia: no esbuild/tailwind platform suffix recorded for ${system}; add one to platformSuffix in nix/packages/flake-module.nix (tailwindBinaries below needs an entry too)");

      # Pre-fetch npm dependencies (required for sandbox build)
      npmDeps = pkgs.fetchNpmDeps {
        src = ../../assets;
        hash = "sha256-Ykq1s0zWPyZNgf8iKeVsATHsplXnHeVKxhvtlLHlcyM=";
      };

      # Tailwind CSS v4 standalone binary. nixpkgs does ship tailwindcss_4, but
      # at 4.2.0, behind the 4.3.3 pinned in lockstep across config, nix and npm
      # (344719f8), so the release binary is fetched directly instead.
      tailwindVersion = "4.3.3";

      # Keep in sync with tailwindVersion. These are content hashes, so every
      # entry can be computed from any machine regardless of its own platform:
      #   nix store prefetch-file \
      #     https://github.com/tailwindlabs/tailwindcss/releases/download/v<version>/<binary>
      tailwindBinaries = {
        "x86_64-linux" = {
          name = "tailwindcss-linux-x64";
          hash = "sha256-3GGzrGuMnKh0wMxMV7JAl5GmTFVAQEyl9TZzYLq8MTo=";
        };
        "aarch64-linux" = {
          name = "tailwindcss-linux-arm64";
          hash = "sha256-Vf0LJBIU7/PeHo7k8ieWZi8tLnpJvPynR3z9C6w5gZU=";
        };
        "x86_64-darwin" = {
          name = "tailwindcss-macos-x64";
          hash = "sha256-eSLglT8hEMBZduO/WPFOZD2QQnV152a31DP1+Ay+5+E=";
        };
        "aarch64-darwin" = {
          name = "tailwindcss-macos-arm64";
          hash = "sha256-zfZGcCmHp0NGTf9NnGD9RIDRwec92Bmppn8QeIFdzp0=";
        };
      };

      # Fail loudly on an unrecognised system. The previous fallback handed out
      # an all-A placeholder hash, which surfaced as an opaque hash mismatch
      # rather than "this platform was never set up".
      tailwindBinary = tailwindBinaries.${system} or (throw
        "mydia: no Tailwind ${tailwindVersion} binary recorded for ${system}; add one to tailwindBinaries in nix/packages/flake-module.nix (platformSuffix above needs an entry too)");

      tailwindcss_4_src = pkgs.fetchurl {
        # Version-qualified on purpose. Fixed-output derivations are keyed by
        # (hash, name) and ignore the URL entirely, so a stale hash can be
        # satisfied by whatever is already in the local store under the same
        # name. That is exactly what happened when 344719f8 bumped the version
        # without updating the hash: the 4.1.18 artifact already present
        # matched, the package built 4.1.18 while claiming 4.3.3, and it only
        # failed on machines with a cold store. Including the version in the
        # name makes a stale hash force a real fetch, and fail immediately.
        name = "tailwindcss-${tailwindVersion}-${platformSuffix}";
        url = "https://github.com/tailwindlabs/tailwindcss/releases/download/v${tailwindVersion}/${tailwindBinary.name}";
        hash = tailwindBinary.hash;
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
        # autoPatchelfHook and the libstdc++ wrapping below are ELF-only. The
        # macOS builds are self-contained Mach-O binaries and need neither.
        nativeBuildInputs = [ pkgs.makeWrapper ]
          ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.autoPatchelfHook;
        buildInputs =
          pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.stdenv.cc.cc.lib;
        installPhase = ''
          mkdir -p $out/bin
          cp $src $out/bin/tailwindcss
          chmod +x $out/bin/tailwindcss
        '';
        # bun unpacks the bundled @parcel/watcher native addon to /$bunfs/root/
        # at RUNTIME, so autoPatchelfHook cannot reach it — it does not exist at
        # build time. Without libstdc++ on the loader path the addon fails with
        # ERR_DLOPEN_FAILED. Wrap rather than patch.
        postFixup = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
          wrapProgram $out/bin/tailwindcss \
            --prefix LD_LIBRARY_PATH : ${pkgs.stdenv.cc.cc.lib}/lib
        '';
        # Assert the packaged binary really is the pinned version. Combined with
        # the version-qualified src name, this makes a hash/version mismatch a
        # build failure rather than a silently wrong Tailwind, and it also
        # re-checks that the payload survived fixup (see dontStrip above): a
        # stripped binary runs as bare Bun and prints no Tailwind version.
        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck
          if ! $out/bin/tailwindcss --help 2>&1 | grep -q "v${tailwindVersion}"; then
            echo "ERROR: packaged Tailwind does not report v${tailwindVersion}:" >&2
            $out/bin/tailwindcss --help 2>&1 | head -2 >&2
            exit 1
          fi
          runHook postInstallCheck
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

          # Environment variables for build and release phases. Under nixpkgs
          # structuredAttrs, variables must be declared in `env` rather than as
          # top-level derivation attributes.
          env = {
            HOME = "/tmp";
          } // pkgs.lib.optionalAttrs (databaseType != null) {
            DATABASE_TYPE = databaseType;
          };

          # Remove dev/test dependencies from the build
          removeCookie = false;

          # Pre-fetched npm dependencies
          inherit npmDeps;
          npmRoot = "assets";

          # The Cardigann guest is not part of the package: installs that opt in
          # (CARDIGANN_ENGINE=prowlarr or the Indexers page) download it at runtime, verified
          # against native/cardigann_guest/ARTIFACT_SHA256, which the build
          # compiles in. The compiler step that fetches it for development is
          # skipped.
          MYDIA_SKIP_CARDIGANN_FETCH = "1";

          # Set up Cargo vendoring for the Rust NIFs and plugin guests
          postConfigure = ''
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

            # Same for the bundled plex plugin guest.
            mkdir -p plugins/plex/.cargo
            cat > plugins/plex/.cargo/config.toml <<CARGO_EOF
            [source.crates-io]
            replace-with = "vendored-sources"

            [source.vendored-sources]
            directory = "${plexCargoDeps}"
            CARGO_EOF

            # Same for the subtitle re-sync NIF, compiled by rustler during
            # `mix compile`.
            mkdir -p native/mydia_subsync/.cargo
            cat > native/mydia_subsync/.cargo/config.toml <<CARGO_EOF
            [source.crates-io]
            replace-with = "vendored-sources"

            [source.vendored-sources]
            directory = "${subsyncCargoDeps}"
            CARGO_EOF
          '';

          # Configure asset compilation
          preBuild = ''
            # Create deps symlinks for packages linked in _build/prod/lib but
            # missing from deps/ (e.g. buildRebar3 packages like hackney, luerl).
            # This runs here rather than in postConfigure: nixpkgs links the
            # mixNixDeps sources into deps/ from a postConfigure hook, and the
            # postConfigure attribute runs before those hooks, when deps/ does
            # not exist yet.
            mkdir -p deps
            for lib_dir in _build/prod/lib/*; do
              dep_name=$(basename "$lib_dir")
              if [ ! -e "deps/$dep_name" ]; then
                # Link the full app directory (not just /src) so Mix finds .app files
                ln -s "$(readlink -f "$lib_dir")" "deps/$dep_name"
              fi
            done
            echo "deps/ holds $(ls deps/ | wc -l) entries"

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

          # Boot the release once. `bin/mydia eval` runs the config providers
          # and Config.Provider.boot/2's compile_env validation, which is
          # exactly what aborted the v0.14.0-beta.4 NixOS module, without
          # starting an application, opening a database, or touching the
          # network. Without this the same failure only appears in the
          # push-only VM test, as a 900 second timeout on wait_for_unit with
          # the real error buried in the guest's journal.
          #
          # config/runtime.exs requires these three under SQLite.
          # Mydia.Release.Env.fetch_secret!/2 enforces a 32 character floor, so
          # these are long enough to pass and are obvious throwaways; they
          # never leave the sandbox and never reach the output. RELEASE_TMP has
          # to be redirected because it defaults to a directory inside the
          # release root, which is the read-only store path.
          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck

            export RELEASE_TMP=$(mktemp -d)
            export RELEASE_DISTRIBUTION=none
            export SECRET_KEY_BASE=nix-install-check-not-a-real-secret-key-base-value
            export GUARDIAN_SECRET_KEY=nix-install-check-not-a-real-guardian-secret-key
            ${if databaseType == "postgres" then "" else "export DATABASE_PATH=$RELEASE_TMP/install-check.db"}
            export MYDIA_DATA_DIR=$RELEASE_TMP

            echo "install check: booting the release to validate its configuration"
            $out/bin/mydia eval '
              expected = ${if databaseType == "postgres" then "Ecto.Adapters.Postgres" else "Ecto.Adapters.SQLite3"}
              actual = Application.fetch_env!(:mydia, :database_adapter)
              if actual != expected do
                IO.puts(:stderr, "FATAL: expected database adapter #{inspect(expected)}, got #{inspect(actual)}")
                System.halt(1)
              end
            '

            runHook postInstallCheck
          '';
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
        # Exposed so the pinned Tailwind binary can be built and version-checked
        # per platform (`nix build .#tailwindcss`) without building the whole
        # Elixir release. The hash table above was wrong on every platform and
        # nothing could catch it cheaply.
        tailwindcss = tailwindcss_4;
      };
    };
}
