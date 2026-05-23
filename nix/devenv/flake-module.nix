# flake-parts module exposing the mydia-rs devenv shell.
#
# Two entry points it produces:
#
#   nix run .#mydia-rs-dev-devenv-up         (alias: `./dev rs up`)
#     -> devenv up — launches `dx serve` under process-compose.
#     Ctrl-C tears every child down cleanly.
#
#   nix develop --impure .#mydia-rs-dev      (alias: `./dev rs shell`)
#     -> drops you in a shell with the dev toolchain on PATH
#     (dx, sqlx-cli, rust, ffmpeg, ...). Useful for one-off cargo
#     commands or running `dx build` by hand.
#
# Hot-reload model: `dx serve --hot-patch`. dx 0.7 owns:
#   - both server (native) and client (wasm32) cargo builds, in
#     parallel under the `@client` / `@server` channels
#   - the Subsecond hot-patch machinery, which patches Rust code in
#     the running process (server + wasm) without a kill-restart
#   - RSX hot-reload over the dev WebSocket
#   - the auto-downloaded standalone tailwindcss binary, run with
#     `--watch` against `Dioxus.toml`'s tailwind_input/tailwind_output
#   - SSR HTML <script> injection that boots the wasm hydration client
#   - graceful kill-restart of the server binary when a change is
#     outside hot-patch scope (signature changes, new deps, etc.)
#
# Why one process: dx's serve loop is itself a process-compose-shaped
# thing — putting it under our process-compose lets `./dev rs down`
# kill the whole tree via the same setsid / pgid trick the old
# cargo-watch setup used, while letting dx own the cargo + tailwind
# orchestration.

{ inputs, ... }:

{
  imports = [
    inputs.devenv.flakeModule
  ];

  perSystem = { pkgs, lib, ... }: {
    devenv.shells.mydia-rs-dev = {
      # devenv-under-flake-parts needs the repo root at eval time;
      # `inputs.devenv-root` lets us read it from a file that the
      # shell-bootstrap replaces with the real path at run time.
      devenv.root =
        let
          devenvRootFileContent = builtins.readFile inputs.devenv-root.outPath;
        in
        lib.mkIf (devenvRootFileContent != "") devenvRootFileContent;

      # Don't impose devenv-managed languages on top of what the
      # rust-toolchain.toml in mydia-rs/ wants. The toolchain comes
      # in as nixpkgs binaries via `packages` below.
      languages.rust.enable = false;

      # process-compose's TUI dashboard opens /dev/tty, which makes
      # `./dev rs up` fail when invoked from a non-interactive shell
      # (CI, agents, backgrounded). Plain log streaming is fine for
      # the dev loop; if you want the dashboard manually, run
      # `process-compose attach` after `./dev rs up`.
      process.manager.implementation = "process-compose";
      process.managers.process-compose = {
        tui.enable = false;
      };

      packages = with pkgs; [
        # --- Rust toolchain (matches existing devShells/default) ---
        rustc
        cargo
        rustfmt
        clippy
        sqlx-cli

        # --- Media / asset helpers ---
        ffmpeg          # exercised by U16 file_analyzer + U19 HLS
        pkg-config
        openssl
        openssl.dev
        postgresql.dev

        # psql client for ad-hoc inspection of the sqlx prepare DB
        # (the postgres service below ships its own server binaries
        # but services.postgres only adds them to PATH inside the
        # process; pulling postgresql_16 here lets `psql` work from
        # any devenv shell).
        postgresql_16

        # --- Convenience ---
        curl            # healthcheck loop + manual probes
        git

        # NOTE: dioxus-cli is NOT pulled from nixpkgs. nixpkgs ships
        # 0.7.3, but the dioxus crate dep is 0.7.9; dx fails its own
        # crate<->cli version check between those. The enterShell
        # hook below pins 0.7.9 via `cargo install` into ~/.cargo/bin
        # (cached across rebuilds).
        #
        # NOTE: tailwindcss is NOT pulled from nixpkgs either. dx 0.7
        # auto-downloads the standalone Tailwind v4 binary on first
        # `dx serve` / `dx build` (cached under ~/.dioxus). Bringing
        # our own would just be a second copy that fights dx's.
      ];

      # ----------------------------------------------------------
      # Service: Postgres 16 (for the sqlx compile-time prepare DB)
      #
      # Pinned to Postgres 16 to match the matrix in
      # `.github/workflows/ci-mydia-rs.yml` (test-postgres and
      # sqlx-prepare-check both run `postgres:16`). Keeping the dev
      # and CI engines in lockstep means a `cargo sqlx prepare`
      # cache generated locally validates against the same engine
      # CI later checks it against.
      #
      # The service is wired up to `devenv up` but the dev loop
      # does NOT require it. SQLite-only contributors can ignore
      # Postgres entirely; it only matters when editing a query
      # behind a `sqlx::query!`/`query_as!` macro and refreshing
      # the offline cache under `mydia-rs/.sqlx/`.
      #
      # The DATABASE_URL exported in enterShell points here so
      # `cargo sqlx prepare --workspace` (./dev rs sqlx-prepare)
      # has a target out of the box. Phoenix's own dev Postgres
      # binds host port 5433 (see `compose.yml`) so the two don't
      # collide.
      #
      # One-time setup to populate the schema (the prepare DB
      # mirrors the Phoenix-owned migration set, mydia-rs never
      # writes a migration):
      #
      #   DATABASE_TYPE=postgres \
      #   DATABASE_PORT=5432 \
      #   DATABASE_NAME=mydia_rs_prepare \
      #   DATABASE_USER=postgres \
      #   DATABASE_PASSWORD="" \
      #   DATABASE_HOST=localhost \
      #   ./dev mix ecto.migrate
      #
      # Re-run whenever a Phoenix migration changes the columns or
      # types that mydia-rs reads. See `mydia-rs/README.md` for the
      # full walk-through.
      # ----------------------------------------------------------
      services.postgres = {
        enable = true;
        package = pkgs.postgresql_16;
        listen_addresses = "127.0.0.1";
        port = 5432;
        initialDatabases = [
          { name = "mydia_rs_prepare"; }
        ];
      };

      # ----------------------------------------------------------
      # Process: dx serve
      #
      # Drives the full dev loop. dx handles the cargo build, the
      # wasm build, the tailwindcss watcher, the hot-patch / hot-
      # reload websocket, the SSR <script> injection — everything
      # we used to wire up by hand.
      # ----------------------------------------------------------
      processes.dx-serve = {
        exec = ''
          # Env vars are exported here directly because devenv's
          # top-level `env` config doesn't always propagate to
          # process-compose's child processes (figment ends up
          # reading config defaults instead). Exporting inline is
          # the load-bearing fix.

          # Lock-skip env intentionally doesn't start with MYDIA_
          # because figment grabs all MYDIA_* env vars as Config
          # schema overrides and `deny_unknown_fields` would reject
          # an unrecognized name like MYDIA_RUNTIME_LOCK_ENABLED.
          # Without skip-lock, dx's kill-restart on a full rebuild
          # leaves a 30-second-fresh lock row that blocks the new
          # binary from starting. Hot-patch never restarts so the
          # lock is held continuously; this env var only matters
          # for the full-rebuild path.
          export MYDIA_RS_DEV_SKIP_LOCK=true
          export MYDIA_DATABASE__TYPE=sqlite
          # Point at the repo-root SQLite file Phoenix maintains (see
          # `config/dev.exs:30` — `Path.expand("../mydia_dev.db",
          # __DIR__)`). The rewrite plan is explicit that mydia-rs
          # reads the schema Phoenix created; pointing at a separate
          # empty `mydia_rs_dev.db` leaves the `users` table missing,
          # and every server fn that touches it 500s. Run
          # `./dev mix ecto.migrate` once (in the Phoenix container)
          # to create / advance this file.
          export MYDIA_DATABASE__PATH=../mydia_dev.db
          export MYDIA_SERVER__HOST=0.0.0.0
          export MYDIA_SERVER__PORT=4002
          export MYDIA_LOGGING__LEVEL=info
          export MYDIA_LOGGING__FORMAT=text

          # dx uses ~/.cargo/bin and ~/.dioxus for its caches; make
          # sure both are on PATH so the pinned cli + downloaded
          # tailwindcss resolve.
          export PATH="$HOME/.cargo/bin:$PATH"

          cd "$DEVENV_ROOT/mydia-rs"

          # `dx serve` flags:
          #   --package mydia-rs-app : the dual-target binary.
          #   --web                  : force the wasm client build.
          #                            Even though our `dioxus`
          #                            dep enables `fullstack`,
          #                            dx 0.7.9's auto-detection
          #                            stops at the server target
          #                            unless --web is explicit;
          #                            without it the SSR page
          #                            renders but the wasm
          #                            hydration shim never gets
          #                            a bundle to import and
          #                            interactive forms (login,
          #                            profile) are dead.
          #   --port 4002            : honored by axum bind via
          #                            dioxus_cli_config; also the
          #                            port dx's proxy listens on.
          #   --addr 0.0.0.0         : bind on all interfaces so
          #                            Phoenix-side proxy + Docker
          #                            host reach the server.
          #   --open false           : we're not running a desktop
          #                            browser from this shell.
          #
          # `--hot-patch` is intentionally OFF. dx 0.7.9 currently
          # fails workspace fullstack builds with "Missing linker
          # args for fat link" when --hot-patch is set; the fix
          # is tracked upstream. Until then, dx falls back to
          # graceful kill-restart on every change — RSX hot-reload
          # still works (no rebuild, sub-second), and full rebuilds
          # take a few seconds with the warm incremental cache.
          # Re-enable once dx ships the fix.
          exec dx serve \
            --package mydia-rs-app \
            --web \
            --port 4002 \
            --addr 0.0.0.0 \
            --open false
        '';
      };

      # One-time installs / sanity checks. devenv runs this on
      # interactive shell entry; the same path runs implicitly
      # before `devenv up` boots the processes.
      enterShell = ''
        # Pin dx 0.7.9 to match the dioxus crate dep. nixpkgs's
        # dioxus-cli 0.7.3 fails the cli<->crate version check.
        # Cached at $CARGO_HOME/bin (default ~/.cargo/bin) so
        # subsequent shells are instant. dx is the only driver for
        # the dev loop now; without it, `./dev rs up` fails.
        DX_WANT="0.7.9"
        DX_CUR=$(command -v dx >/dev/null 2>&1 && dx --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "none")
        if [ "$DX_CUR" != "$DX_WANT" ]; then
          echo "[devenv] installing dioxus-cli $DX_WANT (current: $DX_CUR) ..."
          cargo install --locked --version "$DX_WANT" dioxus-cli || {
            echo "[devenv] ERROR: dioxus-cli install failed — './dev rs up' will not work until this is resolved" >&2
          }
        fi
        export PATH="$HOME/.cargo/bin:$PATH"

        # Point sqlx-cli + the compile-time `query!` / `query_as!`
        # macros at the devenv-managed Postgres 16 prepare DB. The
        # service block above creates `mydia_rs_prepare` empty; the
        # operator runs Phoenix's ecto.migrate against it once (see
        # the comment on `services.postgres` above) so the schema is
        # populated before `cargo sqlx prepare` runs. The URL is set
        # unconditionally: both the SQLite-only and Postgres-prepare
        # workflows tolerate it being present (sqlx only reads it
        # when a `query!` macro forces an offline-or-live check).
        export DATABASE_URL="postgres://postgres@localhost:5432/mydia_rs_prepare"

        # Ensure the tailwind.built.css placeholder exists. dx serve
        # / dx build will overwrite it with real compiled CSS; we
        # only create it so plain `cargo check` / `cargo build` (no
        # dx in the loop) doesn't fail at `asset!("/assets/
        # tailwind.built.css")` resolution on a fresh checkout.
        #
        # Guard on DEVENV_ROOT being a real directory — if it's empty
        # or wrong (e.g., shell entered with `nix develop` without the
        # ./dev wrapper), skip the placeholder rather than creating a
        # `/mydia-rs/...` path or a sibling `mydia-rs/mydia-rs/` dir.
        if [ -n "$DEVENV_ROOT" ] && [ -d "$DEVENV_ROOT/mydia-rs/crates/web/assets" ]; then
          BUILT_CSS="$DEVENV_ROOT/mydia-rs/crates/web/assets/tailwind.built.css"
          if [ ! -f "$BUILT_CSS" ]; then
            printf '%s\n' '/* placeholder — overwritten by dx serve / dx build */' > "$BUILT_CSS"
          fi
        fi

        if [ -t 1 ]; then
          echo ""
          echo "mydia-rs dev environment (devenv) loaded."
          echo "  dx:           $(dx --version 2>/dev/null || echo 'NOT INSTALLED')"
          echo "  rustc:        $(rustc --version 2>&1)"
          echo "  DATABASE_URL: $DATABASE_URL"
          echo ""
          echo "Run './dev rs up' to launch 'dx serve' (host port 4002)."
          echo "Run './dev rs sqlx-prepare' to refresh the offline query cache"
          echo "(needs the postgres service from 'devenv up' + a one-time"
          echo "ecto.migrate run; see mydia-rs/README.md)."
          echo ""
        fi
      '';
    };
  };
}
