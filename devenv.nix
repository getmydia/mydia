{ pkgs, lib, config, ... }:

# Mydia developer environment (devenv.sh).
#
# Replaces the Docker-based `./dev` toolchain. The daily loop (Phoenix server,
# `mix test`, `mix precommit`, Flutter codegen) runs natively in this shell;
# each git worktree derives its own non-colliding ports and isolated state.
#
# The Elixir minor and the OTP major are NOT named in this file. They live in
# .elixir-version and .otp-version, resolved as a matched pair by
# beam-version.nix, which this file and nix/packages/flake-module.nix import
# and the Dockerfile's base tag is checked against. ci-nix.yml's
# "Check / BEAM Pin" job fails the build if any other file names either one.
#
# Two toolchains are NOT listed above and must not be named here, because each
# lives in exactly one file that everything else reads:
#   - Flutter lives in player/.fvmrc, resolved by player/flutter-version.nix.
#     devenv, the Android shell (nix/devShells), all four workflows and the
#     Dockerfile read that one file, and a mismatch between it and nixpkgs is an
#     eval error rather than something a reader has to notice.
#   - Rust lives in rust-toolchain.toml, read by this file, by cargokit, by both
#     Dockerfiles, and by every rustup proxy invocation in the tree.
# CI fails the build if any other file names a Rust version.

let
  # Rust version comes from rust-toolchain.toml, the same file cargokit, both
  # Dockerfiles and every rustup proxy read. Never name a Rust version here.
  rustToolchain = (builtins.fromTOML (builtins.readFile ./rust-toolchain.toml)).toolchain;

  # devenv's languages.rust.version wants a bare version string, so a floating
  # channel ("stable") would silently become version = "stable" and fail deep
  # inside the rust overlay. Fail here instead, naming the constraint.
  rustVersion =
    assert lib.assertMsg
      (builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" rustToolchain.channel != null)
      ''
        rust-toolchain.toml declares channel = "${rustToolchain.channel}", but
        devenv.nix needs an exact version (for example "1.96.0"). A floating
        channel cannot be expressed as languages.rust.version.
      '';
    rustToolchain.channel;

  # ── Per-worktree deterministic ports (KTD5 / R8) ────────────────────────────
  # Hash the absolute worktree path (config.devenv.root, known at eval time) to a
  # stable 0..99 offset, then derive a 10-port window. Stable across restarts and
  # branch renames; changes only if the checkout physically moves. Overridable
  # per worktree via devenv.local.nix (see devenv.local.nix.example, R9).
  hexMap = {
    "0" = 0; "1" = 1; "2" = 2; "3" = 3; "4" = 4; "5" = 5; "6" = 6; "7" = 7;
    "8" = 8; "9" = 9; "a" = 10; "b" = 11; "c" = 12; "d" = 13; "e" = 14; "f" = 15;
  };
  hexToInt = s: lib.foldl' (acc: c: acc * 16 + hexMap.${c}) 0 (lib.stringToCharacters s);
  digest = builtins.substring 0 8 (builtins.hashString "sha256" config.devenv.root);
  raw = hexToInt digest;
  # lib.mod is integer modulo (Nix `/` on integers is already integer division,
  # but the named helper makes the integer intent unambiguous — the offset must
  # be a whole 0..99 so derived ports stay integers).
  offset = lib.mod raw 100;
  portBase = 4000 + offset * 10;
  phxPort = portBase;
  p2pPort = portBase + 1;
  pgPort = portBase + 2;
  flutterPort = portBase + 3;
  httpsPort = portBase + 4;

  # ── Shared caches outside any worktree (KTD4 / R11) ─────────────────────────
  # Immutable/derived downloads are shared so a second worktree's first run
  # reuses the first's; mutable state stays per-worktree: pg data and _build
  # live under .devenv/ automatically, and the SQLite mydia_dev.db lives at the
  # worktree root (config/dev.exs: Path.expand "../mydia_dev.db") — isolated
  # because each worktree is a separate checkout, not because it is under .devenv/.
  sharedCache = "${builtins.getEnv "HOME"}/.cache/mydia-devenv";

  # ── Postgres gating (R4) ────────────────────────────────────────────────────
  # SQLite is the default and needs no service. Postgres only matters under
  # DATABASE_TYPE=postgres; gate on the eval-time env so SQLite worktrees never
  # start a Postgres process.
  dbType = builtins.getEnv "DATABASE_TYPE";
  usePostgres = dbType == "postgres" || dbType == "postgresql";

  # ── CI task guard (KTD7) ────────────────────────────────────────────────────
  # In CI the workflow runs its own hex/deps/ecto/asset setup explicitly inside
  # the devenv shell, so the first-run tasks below must NOT auto-fire on shell
  # entry — otherwise every CI job would run `flutter pub get` and a dev-DB
  # migrate against dev defaults, polluting results and inflating the measured
  # closure. GitHub Actions (and most CI) export CI=true; read it at eval time
  # and drop the enterShell trigger when set. Local shells are unaffected.
  isCI = builtins.getEnv "CI" != "";
  onEnterShell = lib.optionals (!isCI) [ "devenv:enterShell" ];

  # ── Flutter (single source of truth) ────────────────────────────────────────
  # player/.fvmrc is the only place the Flutter version is written. The resolver
  # throws if nixpkgs disagrees, so a `devenv update` that moves Flutter fails
  # loudly here instead of silently shipping a different SDK than CI uses.
  flutterPkg = import ./player/flutter-version.nix { inherit pkgs; };

  # Elixir and OTP (single source of truth). .elixir-version and .otp-version
  # are the only places the Elixir minor and the OTP major are written.
  # beam-version.nix draws both from one beam set, so the pair on PATH always
  # matches: devenv's languages.elixir adds only the elixir package and does
  # not pull a matching OTP. The resolver throws if this nixpkgs lacks either
  # attribute, so a lock move that drops one fails loudly here.
  beamPin = import ./beam-version.nix { inherit pkgs; };
in
{
  languages.elixir = {
    enable = true;
    package = beamPin.elixir;
  };

  # Rust version is NOT named here: it comes from rust-toolchain.toml via the
  # `rustVersion` binding above. `components` replaces (not appends) the
  # defaults, so rustc/cargo are restated alongside the lint/analysis tools.
  # `targets` is the Nix-side list and is intentionally different from the
  # toolchain file's: this is what the dev shell offers, not what ships.
  languages.rust = {
    enable = true;
    channel = "stable";
    version = rustVersion;
    targets = [ "wasm32-unknown-unknown" "wasm32-wasip2" ];
    components = [ "rustc" "cargo" "clippy" "rustfmt" "rust-analyzer" "rust-src" ];
  };

  # Remaining dev toolchain. Flutter comes from nixpkgs (KTD3); the Android
  # shell (nix/devShells) resolves it through the same player/flutter-version.nix,
  # so the NixOS dynamic-linker/patchelf handling is proven for this codebase. wasm-tools is carried from the flake's
  # shells (used by scripts/check-plugins.sh).
  #
  # The Flutter version is NOT named here. It comes from player/.fvmrc through
  # flutterPkg above, shared with the Android shell, CI and Docker.
  packages = with pkgs; [
    flutterPkg

    # OTP and rebar3, from the resolver's beam set rather than
    # languages.erlang. The pinned devenv's languages.erlang builds rebar3 as
    # nixpkgs' default-OTP rebar3 with this OTP swapped into buildInputs, which
    # skips nixpkgs' rebar3 patch for the newer OTP major, and the build fails.
    # The set's own rebar3 is the correct, binary-cached build. devenv fixed
    # its module upstream (cachix/devenv 84b8f8dfe2); return to
    # languages.erlang once devenv.lock's devenv input and CI's devenv CLI both
    # include that commit, with its lsp option off. The Erlang language server
    # that module adds by default is left out on purpose: nixpkgs ships it as
    # prebuilt binaries for older OTP majors only, so it cannot match this
    # OTP, and the repo has no Erlang sources for it to serve.
    beamPin.erlang
    beamPin.beam.rebar3

    # Node.js for assets
    nodejs

    # Database CLI (SQLite is the default adapter)
    sqlite

    # Media processing
    ffmpeg
    # fpcalc, the audio fingerprinter behind intro/credits segment detection
    chromaprint

    # Build tools for NIFs (bcrypt_elixir, argon2_elixir, membrane, exqlite)
    gnumake
    pkg-config

    # deps + general utilities
    git
    curl

    # Rasterize the player's SVG logo into the web icon set
    # (player/tool/gen-web-icons.sh). librsvg is cross-platform in nixpkgs, so it
    # belongs in this unconditional list, not the Linux-gated one below.
    librsvg

    # Inspect/validate WASM components (WIT plugin guests)
    wasm-tools

    # player/tool/build_web.sh builds mydia_p2p_core for wasm through
    # `flutter pub run flutter_rust_bridge build-web`, which shells out to
    # `wasm-pack` directly (not the cargo-installed flutter_rust_bridge_codegen
    # binary). Without wasm-pack on PATH, that Dart code falls back to `cargo
    # install wasm-pack`, which compiles the crate from source and costs
    # minutes on every CI run instead of resolving a Cachix-cached derivation.
    # Verified this pair closes the gap rather than just shrinking it: with
    # both present, wasm-pack finds this wasm-opt on PATH directly
    # ("found wasm-opt at .../binaryen-.../bin/wasm-opt") and never downloads
    # one. It still downloads wasm-bindgen from a GitHub release regardless,
    # since that one must match the exact wasm-bindgen crate version pinned in
    # Cargo.lock and wasm-pack does not trust a PATH copy for that. Fine on a
    # normal internet-connected runner, just not eliminated by this package.
    wasm-pack
    binaryen
  ]
  # ── Linux-only packages (KTD7) ────────────────────────────────────────────
  # These have meta.platforms = linux, so listing them unconditionally made the
  # whole devenv-shell derivation fail to evaluate on darwin ("Package 'chromium'
  # is not available on the requested hostPlatform") — breaking every ./dev
  # command that enters the shell, not just browser tests. Keep this list
  # Linux-gated; darwin covers each one natively:
  #   inotify-tools  Phoenix live reload uses fs_events on darwin
  #   chromium/…     Wallaby feature tests are Linux/CI-only (see env below)
  #   gcc            NIFs build against the host clang from the Xcode CLT
  #   libva-utils    VAAPI is Linux/DRM only; its libdrm dependency has no
  #                  darwin meta.platforms entry, so this belongs here rather
  #                  than beside ffmpeg above
  ++ lib.optionals pkgs.stdenv.isLinux (with pkgs; [
    gcc
    inotify-tools
    chromium
    chromedriver
    # vainfo, which Mydia.Streaming.HardwareAccel.Probe shells out to when
    # detecting VAAPI capabilities. libva alone (an ffmpeg dependency) does not
    # provide the CLI; without it the opt-in hwaccel_live_test.exs suite could
    # never run outside the production container.
    libva-utils
  ]);

  env = {
    # Locale for Elixir (mirrors the retired default devShell).
    LANG = "C.UTF-8";
    LC_ALL = "C.UTF-8";

    # IEx shell history.
    ERL_AFLAGS = "-kernel shell_history enabled";

    # C cross-compilation for the wasm32-unknown-unknown target listed under
    # languages.rust above. `ring`, which is rustls' crypto provider and so
    # iroh's, compiles C sources through cc-rs, and cc-rs falls back to the
    # ambient CC, which nix sets to a host gcc wrapper. That silently yields
    # x86-64 objects rust-lld then refuses to link. The nix clang *wrapper* is
    # no better: it injects host glibc include paths and hardening flags
    # (-fzero-call-used-regs) that clang rejects for wasm. An unwrapped clang
    # plus llvm-ar is what actually cross-compiles.
    CC_wasm32_unknown_unknown = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
    AR_wasm32_unknown_unknown = "${pkgs.llvmPackages.llvm}/bin/llvm-ar";

    # Shared, worktree-independent caches (KTD4 / R11).
    MIX_HOME = "${sharedCache}/mix";
    HEX_HOME = "${sharedCache}/hex";
    PUB_CACHE = "${sharedCache}/pub-cache";
    NPM_CONFIG_CACHE = "${sharedCache}/npm";

    # Per-worktree ports (R8). lib.mkDefault so devenv.local.nix can pin them (R9).
    PORT = lib.mkDefault (toString phxPort);
    HTTPS_PORT = lib.mkDefault (toString httpsPort);
    P2P_BIND_PORT = lib.mkDefault (toString p2pPort);
    FLUTTER_DEV_PORT = lib.mkDefault (toString flutterPort);

    # Postgres connection details (read by config/dev.exs only under
    # DATABASE_TYPE=postgres). devenv's Postgres bootstraps a superuser role
    # named after the OS user with trust auth, so we connect as $USER.
    DATABASE_HOST = "127.0.0.1";
    DATABASE_PORT = lib.mkDefault (toString pgPort);
    DATABASE_USER = lib.mkDefault (builtins.getEnv "USER");
  }
  # Wallaby browser tests. Linux-gated alongside the chromium/chromedriver
  # packages above — interpolating a Linux-only derivation's store path here is
  # what actually broke darwin evaluation, since `env` is evaluated even when
  # the packages are not. config/test.exs falls back to auto-detecting
  # chromedriver when CHROMEDRIVER_PATH is unset, so darwin just needs its own
  # chromedriver on PATH to run feature tests.
  // lib.optionalAttrs pkgs.stdenv.isLinux {
    CHROME_PATH = "${pkgs.chromium}/bin/chromium";
    CHROMEDRIVER_PATH = "${pkgs.chromedriver}/bin/chromedriver";
  }
  # :database_adapter is a compile-time env entry, so a _build compiled for
  # SQLite and reused under DATABASE_TYPE=postgres fails Mix's compile-env
  # validation on every boot, restart-looping phoenix with nothing in its log
  # but that error. Give Postgres its own build root. SQLite keeps the default
  # `_build`, so no existing worktree pays a recompile.
  // lib.optionalAttrs usePostgres {
    MIX_BUILD_ROOT = "_build/postgres";
  };

  # ── Postgres service (R4) ───────────────────────────────────────────────────
  # Data dir lives under the per-worktree .devenv/state/postgres automatically.
  # NOTE: initialDatabases only runs on first init — to change it later, delete
  # .devenv/state/postgres (documented in docs/contributing/setup.md).
  services.postgres = lib.mkIf usePostgres {
    enable = true;
    listen_addresses = "127.0.0.1";
    port = pgPort;
    initialDatabases = [ { name = "mydia_dev"; } { name = "mydia_test"; } ];
  };

  # ── Long-running processes (R5) ─────────────────────────────────────────────
  processes.phoenix.exec = "mix phx.server";

  # The dev database is created and migrated by mydia:ecto, which is deliberately
  # NOT a shell-entry task (see below). Nothing else migrates it: skip_migrations?/0
  # in Mydia.Application returns true whenever RELEASE_NAME is unset, so the
  # supervision tree's Ecto.Migrator never runs under mix. Booting against an
  # unmigrated database dies in ClientHealth.init/1, so wait for the task.
  processes.phoenix.after = [ "mydia:ecto@succeeded" ];

  # build_runner watch performs GraphQL/Riverpod codegen for the player. This is
  # distinct from MydiaWeb.FlutterWatcher (config/dev.exs), which runs
  # `flutter build web` on source changes — codegen feeds the web build, so both
  # are needed and they do not double-run.
  processes.flutter-codegen.exec =
    "cd player && flutter pub run build_runner watch";

  # ── First-run / re-entry setup tasks (R6) ───────────────────────────────────
  # Replace docker-entrypoint.sh. Guarded with execIfModified so re-entry is
  # fast: a task only runs when its declared inputs change. The exqlite NIF
  # platform-compat workaround is intentionally NOT ported — one native
  # toolchain compiles exqlite once and keeps it valid (R6).
  tasks = {
    "mydia:hex" = {
      exec = "mix local.hex --force --if-missing && mix local.rebar --force --if-missing";
      before = onEnterShell;
      # Cheap no-op once installed into the shared MIX_HOME.
      execIfModified = [ "mix.exs" ];
    };

    "mydia:deps" = {
      exec = "mix deps.get";
      execIfModified = [ "mix.exs" "mix.lock" ];
      before = onEnterShell;
      after = [ "mydia:hex" ];
    };

    # Deliberately NOT a shell-entry task. Entering a devenv shell must never
    # boot the OTP application and must never start a service; this task does
    # both by necessity, so it belongs to the process graph
    # (processes.phoenix.after) and to `./dev db.setup`.
    "mydia:ecto" = {
      # backup_before_migrate self-skips when nothing is pending AND when the
      # database has no applied migrations at all, so it is a cheap no-op except
      # right before a migration actually runs, keeping the dev-DB safety net
      # the retired docker-entrypoint.sh provided.
      exec = ''
        ${lib.optionalString usePostgres ''
          # Poll for Postgres instead of adding the postgres process as an
          # `after` dependency (its "devenv:processes:postgres@ready" suffix).
          # A task dependency like that makes devenv START Postgres whenever
          # this task runs, which collided with the postmaster already owned
          # by `./dev up -d` ("lock file postmaster.pid already exists", six
          # attempts in 87ms). Polling only ever observes, so the process
          # daemon stays the single owner.
          echo "Waiting for Postgres on $DATABASE_HOST:$DATABASE_PORT…" >&2
          for _ in $(seq 1 60); do
            pg_isready -q -h "$DATABASE_HOST" -p "$DATABASE_PORT" && break
            sleep 0.5
          done

          if ! pg_isready -q -h "$DATABASE_HOST" -p "$DATABASE_PORT"; then
            echo "Postgres is not accepting connections on $DATABASE_HOST:$DATABASE_PORT." >&2
            echo "Start it with './dev up -d'." >&2
            exit 1
          fi
        ''}
        mix do ecto.create --quiet + mydia.backup_before_migrate + ecto.migrate
      '';
      # Deliberately NO execIfModified, overriding this file's original R6
      # caching design (it shipped `execIfModified = [ "priv/repo/migrations" ]`
      # here). Caching this task made devenv report a cached run as
      # "succeeded" without checking whether the database still existed:
      # `./dev db.setup` silently no-op'd against a missing/corrupt database,
      # and `./dev iex`, `./dev phx.server`, and processes.phoenix.after all
      # sailed past a Skipped-but-"succeeded" task into exactly the crash it
      # exists to prevent. The original rationale for caching — keeping shell
      # entry cheap — no longer applies: this task is off shell entry
      # entirely, so every remaining caller (db.setup, iex, phx.server, the
      # process graph) wants it to actually verify state, not skip. Running
      # it unconditionally is safe and cheap: `mix ecto.create --quiet`
      # no-ops on an existing database, `mix mydia.backup_before_migrate`
      # returns `:no_migrations` immediately when nothing is pending, and
      # `mix ecto.migrate` no-ops when the schema is current. The three
      # commands run as one `mix do a + b + c` invocation rather than three
      # separate `mix` processes chained with `&&`, so the added cost is one
      # BEAM boot (~2-3s) on commands that are already starting a BEAM or a
      # whole stack, not three. `mix do` aborts the chain the same way `&&`
      # does: `mydia.backup_before_migrate` calls `exit({:shutdown, 1})` on a
      # failed backup, which terminates the `mix do` process outright (Mix's
      # `do` task has no rescue/catch around each step) before `ecto.migrate`
      # ever runs — verified empirically against the Elixir pinned in
      # .elixir-version with a throwaway two-task `mix do`, not just read off
      # the docs.
      after = [ "mydia:deps" ];
    };

    "mydia:assets" = {
      # assets.setup fetches the standalone tailwind/esbuild binaries; the npm
      # packages (daisyui, alpinejs, …) that @plugin/@import resolve against must
      # be installed separately or CSS rebuilds silently fail.
      exec = "mix assets.setup && cd assets && npm install";
      execIfModified = [ "assets/package.json" "assets/package-lock.json" ];
      before = onEnterShell;
      after = [ "mydia:deps" ];
    };

    "mydia:flutter" = {
      exec = "cd player && flutter pub get";
      execIfModified = [ "player/pubspec.yaml" "player/pubspec.lock" ];
      before = onEnterShell;
    };

    # Override devenv's built-in git-hooks install task. Devenv's default task
    # runs `prek install -c "$DEVENV_ROOT/.pre-commit-config.yaml" -t pre-commit`,
    # which hardcodes `--config="<worktree-root>/.pre-commit-config.yaml"` into the
    # shared `.git/hooks/pre-commit` file. In a multi-worktree repo, entering any
    # worktree's shell rewrites that shared file, moves the previous hook to
    # `pre-commit.legacy` (triggering prek refusal mode), and forces all other
    # worktrees to run against the last-entered worktree's config.
    # Running `prek install -t pre-commit` without `-c` generates a worktree-neutral
    # hook shim that dynamically resolves the active worktree's git root and its
    # `.pre-commit-config.yaml` at commit time, remaining 100% identical and
    # idempotent across all worktrees.
    "devenv:git-hooks:install".exec = lib.mkForce ''
      if ! git rev-parse --git-dir &> /dev/null; then
        exit 0
      fi
      ${pkgs.prek}/bin/prek install -t pre-commit
    '';

    # Keep the full hook suite off shell entry. devenv 2.3.1 added a third
    # scheduling pass ("include every selected task's prerequisites") that pulls
    # `devenv:enterTest` into the shell's task set; its prerequisite
    # `devenv:git-hooks:run` then executes on every `devenv shell` and every
    # direnv load, running prek over the whole tree (dart analyze across
    # player/, four cargo crates, mix format) for ~60s before the prompt
    # returns. 2.2.2 entered the same shell in 3s. Upstream:
    # https://github.com/cachix/devenv/issues/3184
    #
    # Clearing the `before` edge takes `devenv:git-hooks:run` out of every
    # graph that reaches it, so nothing schedules it implicitly. Hooks still
    # run where they matter: prek at commit time via .git/hooks/pre-commit, and
    # `mix precommit` / CI on demand. Nothing in this repo invokes
    # `devenv test`, so losing the enterTest wiring costs nothing. Revisit once
    # 3184 is fixed upstream.
    "devenv:git-hooks:run".before = lib.mkForce [ ];
  };

  # ── Git hooks (KTD7 / R17) ──────────────────────────────────────────────────
  # devenv owns the generated .pre-commit-config.yaml (git-ignored). Hooks run
  # inside this shell, so cargo/mix/dart resolve to the pinned toolchain — no
  # `nix develop .#rust -c …` subshell needed. Patterns mirror the retired
  # .pre-commit-config.yaml.
  git-hooks.hooks = {
    cargo-fmt = {
      enable = true;
      name = "cargo fmt";
      entry = "cargo fmt --manifest-path native/mydia_p2p/Cargo.toml -- --check";
      files = "^native/.*\\.rs$";
      pass_filenames = false;
    };
    cargo-clippy = {
      enable = true;
      name = "cargo clippy";
      entry = "cargo clippy --manifest-path native/mydia_p2p/Cargo.toml -- -D warnings";
      files = "^native/.*\\.rs$";
      pass_filenames = false;
    };
    server-fmt = {
      enable = true;
      name = "cargo fmt (server)";
      entry = "cargo fmt --manifest-path server/Cargo.toml --all -- --check";
      files = "^server/.*\\.rs$";
      pass_filenames = false;
    };
    server-clippy = {
      enable = true;
      name = "cargo clippy (server)";
      entry = "cargo clippy --manifest-path server/Cargo.toml --all-targets -- -D warnings";
      files = "^server/.*\\.rs$";
      pass_filenames = false;
    };
    subsync-fmt = {
      enable = true;
      name = "cargo fmt (subsync)";
      entry = "cargo fmt --manifest-path native/mydia_subsync/Cargo.toml -- --check";
      files = "^native/mydia_subsync/.*\\.rs$";
      pass_filenames = false;
    };
    subsync-clippy = {
      enable = true;
      name = "cargo clippy (subsync)";
      entry = "cargo clippy --manifest-path native/mydia_subsync/Cargo.toml --all-targets -- -D warnings";
      files = "^native/mydia_subsync/.*\\.rs$";
      pass_filenames = false;
    };
    plugins-check = {
      enable = true;
      name = "cargo fmt + clippy (wasm plugins)";
      entry = "scripts/check-plugins.sh";
      files = "^plugins/.*\\.rs$";
      pass_filenames = false;
    };
    mix-format = {
      enable = true;
      name = "mix format";
      entry = "mix format --check-formatted";
      files = "\\.(ex|exs|heex)$";
      pass_filenames = false;
    };
    dart-format = {
      enable = true;
      name = "dart format";
      entry = "dart format --set-exit-if-changed --line-length 80";
      files = "\\.dart$";
      excludes = [ "\\.(g|freezed)\\.dart$" ];
    };
    dart-analyze = {
      enable = true;
      name = "dart analyze";
      entry = "dart analyze --fatal-warnings";
      files = "\\.dart$";
      excludes = [ "\\.(g|freezed)\\.dart$" ];
      pass_filenames = false;
    };
    no-scratch-docs = {
      enable = true;
      name = "no scratch docs";
      entry = "scripts/check-no-scratch-docs.sh";
      pass_filenames = false;
      always_run = true;
    };
  };

  # ── Shell-entry banner (R10) ────────────────────────────────────────────────
  enterShell = ''
    echo ""
    echo "Mydia dev environment (devenv) — $DEVENV_ROOT"
    echo "  Phoenix:   http://localhost:$PORT  ·  https://localhost:$HTTPS_PORT"
    echo "  P2P bind:  $P2P_BIND_PORT"
    echo "  Flutter:   dev-server port $FLUTTER_DEV_PORT"
    ${lib.optionalString usePostgres ''
      echo "  Postgres:  127.0.0.1:$DATABASE_PORT (mydia_dev / mydia_test)"''}
    echo "  Toolchain: Elixir $(elixir --version | tail -1 | cut -d' ' -f2) · Rust $(rustc --version | cut -d' ' -f2) · Node $(node --version)"
    echo ""
  '';
}
