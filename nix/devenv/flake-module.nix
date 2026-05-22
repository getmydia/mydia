# flake-parts module exposing the mydia-rs devenv shell.
#
# Two entry points it produces:
#
#   nix run .#mydia-rs-dev-devenv-up         (alias: `./dev rs up`)
#     -> devenv up — launches every declared process under
#     process-compose: cargo-watch + tailwindcss --watch + log tails.
#     Ctrl-C tears every child down cleanly.
#
#   nix develop --impure .#mydia-rs-dev      (alias: `./dev rs shell`)
#     -> drops you in a shell with the dev toolchain on PATH
#     (cargo-watch, tailwindcss, dx, sqlx-cli, rust, ffmpeg, ...).
#     Useful for one-off cargo commands or running `dx serve` by hand.
#
# Hot-reload model: cargo-watch is the canonical "edit Rust file ->
# cargo rebuild -> kill running binary -> start new one" loop. We
# tried dx serve for this and discovered dx 0.7's file watcher
# only pushes RSX hot-patches to a connected wasm browser client;
# it does NOT rebuild the server binary on file change. For our
# SSR-first use case we need full rebuilds, so cargo-watch wins.
# dx 0.7.9 still ships in the shell PATH for manual experimentation
# (`dx serve` directly) and to bake the wasm bundle build pipeline
# for future RSX work.

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
        cargo-watch     # the hot-rebuild driver
        # NOTE: nixpkgs in this lockfile carries dioxus-cli 0.7.3;
        # our dioxus crate dep is 0.7.9. The enterShell hook below
        # installs 0.7.9 into ~/.cargo/bin (cached) for manual
        # `dx serve` invocations and the wasm asset pipeline.

        # --- CSS pipeline ---
        # tailwindcss_4 is the standalone v4 binary (no npm).
        tailwindcss_4

        # --- Media / asset helpers ---
        ffmpeg          # exercised by U16 file_analyzer + U19 HLS
        pkg-config
        openssl
        openssl.dev
        postgresql.dev

        # --- Convenience ---
        curl            # healthcheck loop + manual probes
        git
      ];

      # ----------------------------------------------------------
      # Env passed to every process (process-compose runs them with
      # a stripped environment otherwise).
      # ----------------------------------------------------------
      # ----------------------------------------------------------
      # Process: cargo-watch
      #
      # Watches Rust source under crates/ + bin/ + workspace
      # manifests; on change, runs `cargo run -p mydia-rs-app`.
      # cargo-watch's default behavior is to kill the prior process
      # before re-running, so the lock-skip env above is what makes
      # rapid restarts work.
      # ----------------------------------------------------------
      processes.cargo-watch = {
        # Env vars are exported here directly because devenv's
        # top-level `env` config doesn't always propagate to
        # process-compose's child processes the way you'd expect
        # (figment ends up reading config defaults instead).
        # Exporting inline is the load-bearing fix.
        exec = ''
          mkdir -p /tmp/mydia-rs-devenv-public/assets
          export DIOXUS_PUBLIC_PATH=/tmp/mydia-rs-devenv-public
          # Lock-skip env intentionally doesn't start with MYDIA_
          # because figment grabs all MYDIA_* env vars as Config
          # schema overrides and `deny_unknown_fields` would reject
          # an unrecognized name like MYDIA_RUNTIME_LOCK_ENABLED.
          export MYDIA_RS_DEV_SKIP_LOCK=true
          export MYDIA_DATABASE__TYPE=sqlite
          export MYDIA_DATABASE__PATH=mydia_rs_dev.db
          export MYDIA_SERVER__HOST=0.0.0.0
          export MYDIA_SERVER__PORT=4002
          export MYDIA_LOGGING__LEVEL=info
          export MYDIA_LOGGING__FORMAT=text

          cd "$DEVENV_ROOT/mydia-rs"
          # -s mode (shell command) instead of -x (cargo subcmd) so
          # we can `exec` the built binary directly. With `cargo run`
          # the binary is spawned in its own process group and never
          # sees the SIGTERM cargo-watch sends to its child, leaving
          # the OLD binary alive on port 4002 when the new one tries
          # to bind. With `cargo build && exec ./target/debug/mydia-rs`
          # the binary replaces the shell in cargo-watch's process
          # group, so SIGTERM kills it directly.
          #
          # `dx tools assets` is the link-time post-processing step
          # `dx build` does internally: it patches the binary's
          # embedded asset metadata (replacing the "should be replaced
          # by dx" placeholders with fingerprinted filenames) and
          # copies the referenced files into DIOXUS_PUBLIC_PATH. Without
          # it, `<link rel=stylesheet href=/assets/...>` renders the
          # placeholder string verbatim and the browser 404s on it.
          exec ${pkgs.cargo-watch}/bin/cargo-watch \
            -q -c \
            -w crates -w bin -w Cargo.toml -w Cargo.lock \
            --ignore 'target/**' \
            --ignore 'crates/web/assets/app.built.css' \
            -s 'cargo build -p mydia-rs-app \
                && dx tools assets target/debug/mydia-rs "$DIOXUS_PUBLIC_PATH/assets" \
                && exec ./target/debug/mydia-rs'
        '';
      };

      # ----------------------------------------------------------
      # Process: tailwindcss --watch
      #
      # Compiles crates/web/assets/app.css (Tailwind v4 + DaisyUI
      # source) into crates/web/assets/app.built.css. The asset!
      # macro in crates/web/src/app.rs references the .built.css
      # path. cargo-watch's --ignore rule above keeps the recompiled
      # CSS from triggering a Rust rebuild loop.
      # ----------------------------------------------------------
      processes.tailwindcss = {
        exec = ''
          cd "$DEVENV_ROOT/mydia-rs"
          exec ${pkgs.tailwindcss_4}/bin/tailwindcss \
            -i crates/web/assets/app.css \
            -o crates/web/assets/app.built.css \
            --watch
        '';
      };

      # One-time installs / sanity checks. devenv runs this on
      # interactive shell entry; the same path runs implicitly
      # before `devenv up` boots the processes.
      enterShell = ''
        # Pin dx 0.7.9 to match the dioxus crate dep. nixpkgs's
        # dioxus-cli 0.7.3 fails the cli<->crate version check.
        # Cached at $CARGO_HOME/bin (default ~/.cargo/bin) so
        # subsequent shells are instant. We don't depend on dx
        # for the dev loop (cargo-watch is the watcher), but
        # keeping it installed lets you run `dx serve` manually
        # for wasm-side experimentation.
        DX_WANT="0.7.9"
        DX_CUR=$(command -v dx >/dev/null 2>&1 && dx --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "none")
        if [ "$DX_CUR" != "$DX_WANT" ]; then
          echo "[devenv] installing dioxus-cli $DX_WANT (current: $DX_CUR) ..."
          cargo install --locked --version "$DX_WANT" dioxus-cli || {
            echo "[devenv] WARNING: dioxus-cli install failed — manual dx serve will not work until this is resolved"
          }
        fi
        export PATH="$HOME/.cargo/bin:$PATH"

        if [ -t 1 ]; then
          echo ""
          echo "mydia-rs dev environment (devenv) loaded."
          echo "  cargo-watch:  $(cargo-watch --version 2>&1 | head -1)"
          echo "  tailwindcss:  $(tailwindcss --help 2>&1 | head -1 | sed 's/^≈ //')"
          echo "  dx (manual):  $(dx --version 2>/dev/null || echo 'NOT INSTALLED')"
          echo "  rustc:        $(rustc --version 2>&1)"
          echo ""
          echo "Run 'devenv up' (or './dev rs up') to launch cargo-watch + tailwindcss --watch."
          echo ""
        fi
      '';
    };
  };
}
