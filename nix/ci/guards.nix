# Repository guards that read files and nothing else.
#
#   guards          the file-only steps of ci.yml's old `Guards` job: the Rust
#                   toolchain pin, the Rust lint tables, the Docker
#                   build-identity placement, the pre-migration backup task
#                   and shell-entry purity. The step that runs yq over the
#                   workflows (the required-check aggregators) stays in the
#                   `Guards` job: a check over .github/workflows would rerun
#                   on every workflow edit for no gain.
#   ci-crate-list   scripts/check-rust.sh's manifest glob and the crate list
#                   in nix/ci/rust.nix name the same crates.
#
# Each guard strips full-line comments before matching where the original
# step did. Matching the raw source has already caused two defects: a guard
# regex that matched the comment explaining the code it described, and a
# guard search string that appeared verbatim in a comment inside the block it
# scans. Both would have made CI permanently red, and the workaround each
# time (contorting the prose to dodge the guard) is backwards; narrowing a
# guard's regex to avoid a comment also opens an evasion gap in the code
# match.
{ ... }:

{
  perSystem = { pkgs, lib, ci, ciRust, ... }:
    let
      inherit (ci) sources;
      fs = lib.fileset;
      root = ../..;

      mixLib = import ./mix-lib.nix { inherit pkgs lib; };

      check = { name, set, script, inputs ? [ ] }:
        mixLib.mkLogCheck {
          inherit name script;
          env = { LANG = "C.UTF-8"; };
          src = sources.toSource set;
          nativeBuildInputs = inputs;
        };

      # Every Cargo manifest and clippy config in the tree: the lint-table
      # guard walks the whole repo for both.
      lintManifests = fs.fileFilter
        (f: f.name == "Cargo.toml" || f.name == "clippy.toml" || f.name == ".clippy.toml")
        root;

      nixCrateList = pkgs.writeText "rust-nix-crate-dirs" (lib.concatLines (lib.filter
        (d: lib.hasPrefix "native/" d || lib.hasPrefix "player/rust/" d)
        ciRust.crateDirs));
    in
    {
      ciChecks.guards = check {
        name = "guards";
        set = fs.unions [
          (root + "/Dockerfile")
          (root + "/devenv.nix")
          (root + "/nix/devShells/flake-module.nix")
          (root + "/player/flatpak")
          (root + "/player/appimage")
          (root + "/lib/mix/tasks/mydia.backup_before_migrate.ex")
          (root + "/rust-lints.toml")
          (root + "/scripts/check-rust-lints.sh")
          (root + "/scripts/check_rust_lints.py")
          (root + "/scripts/test-check-rust-lints.sh")
          lintManifests
        ];
        inputs = [ pkgs.python3 pkgs.git pkgs.gawk ];
        script = ''
          FAIL=0

          # The Rust version lives in rust-toolchain.toml alone. Each
          # pattern matches one mechanism that used to hold a hand-copied
          # pin. Keep them narrow; these files are full of unrelated Elixir,
          # NDK and build-tools versions. See issue #252.
          echo "==> Rust toolchain pin"
          if grep -nE -- '--default-toolchain[[:space:]]+[0-9]' Dockerfile; then
            echo "::error::Dockerfile pins a Rust version; it must come from rust-toolchain.toml"
            FAIL=1
          fi
          # Matches a quoted literal (rust-bin.stable."1.96.0") but not an
          # interpolated channel (rust-bin.stable.''${rustChannel}), which is
          # how the Android shell reads the pin.
          if grep -nE 'rust-bin\.[a-z]+\."' nix/devShells/flake-module.nix; then
            echo "::error::the Android shell names a Rust version; read it from rust-toolchain.toml"
            FAIL=1
          fi
          if grep -nE '^[[:space:]]*version[[:space:]]*=[[:space:]]*"[0-9]' devenv.nix; then
            echo "::error::devenv.nix names a version literal; read it from rust-toolchain.toml"
            FAIL=1
          fi
          # The Flatpak build installs rustup with --default-toolchain none
          # and lets it resolve rust-toolchain.toml, so nothing under
          # player/flatpak may name a channel.
          if grep -rnE -- '--default-toolchain[[:space:]]+[0-9]|^[[:space:]]*channel[[:space:]]*=' player/flatpak/ player/appimage/; then
            echo "::error::player/flatpak or player/appimage pins a Rust version; rustup resolves rust-toolchain.toml on its own"
            FAIL=1
          fi

          # Every first-party crate carries a copy of rust-lints.toml's
          # tables. The negative test lists the manifests with git ls-files.
          echo "==> Rust lint tables"
          patchShebangs --build scripts > /dev/null
          git init --quiet
          git add -A
          scripts/check-rust-lints.sh || FAIL=1
          scripts/test-check-rust-lints.sh || FAIL=1

          # BUILD_COMMIT's value changes on every commit, and BuildKit folds
          # a RUN's environment into its ExecOp cache key while a COPY is a
          # FileOp that ignores it. Declared above the dependency layers it
          # therefore leaves `mix deps.get` and `mix deps.compile`
          # permanently uncacheable across commits, in both ci-docker.yml
          # and release.yml, while the build log still reports the COPY
          # above them as CACHED.
          #
          # Below `mix compile` is wrong for the opposite reason: Mydia.System
          # captures BUILD_COMMIT into a module attribute, `mix release`
          # recompiles nothing, and the commit suffix would disappear from
          # the version and from crash reports with no build or test failure.
          # Both bounds are checked. Comments are blanked rather than deleted,
          # so line numbers survive: the Dockerfile comment explaining this
          # rule quotes every string the guard searches for.
          echo "==> Docker build-identity placement"
          scrub="$TMPDIR/Dockerfile.scrubbed"
          sed 's/^[[:space:]]*#.*//' Dockerfile > "$scrub"

          find_line() { grep -nE "$1" "$scrub" | head -1 | cut -d: -f1 || true; }

          deps=$(find_line '^[[:space:]]*mix deps\.compile$')
          comp=$(find_line '^[[:space:]]*mix compile$')
          argline=$(find_line '^ARG BUILD_COMMIT')
          envline=$(find_line '^ENV BUILD_COMMIT')

          anchors=1
          for a in "mix deps.compile:$deps" "mix compile:$comp" \
                   "ARG BUILD_COMMIT:$argline" "ENV BUILD_COMMIT:$envline"; do
            if [ -z "''${a##*:}" ]; then
              echo "::error::Docker build-identity guard lost its anchor (''${a%%:*}); update the guard in nix/ci/guards.nix"
              FAIL=1
              anchors=0
            fi
          done
          if [ "$anchors" = 1 ]; then
            for pair in "ARG:$argline" "ENV:$envline"; do
              kind=''${pair%%:*}
              line=''${pair##*:}
              if [ "$line" -lt "$deps" ]; then
                echo "::error file=Dockerfile,line=$line::$kind BUILD_COMMIT sits above 'mix deps.compile' (line $deps). Its value changes on every commit, so every RUN below it misses cache in ci-docker.yml and release.yml. Keep it beside BUILD_VERSION, just above 'mix compile'."
                FAIL=1
              fi
              if [ "$line" -gt "$comp" ]; then
                echo "::error file=Dockerfile,line=$line::$kind BUILD_COMMIT sits below 'mix compile' (line $comp). Mydia.System captures it into a module attribute at compile time and 'mix release' recompiles nothing, so the commit suffix would silently vanish from the version and from crash reports."
                FAIL=1
              fi
            done
          fi

          # This task runs from devenv's mydia:ecto against a database that
          # may have no tables yet. Booting the supervision tree there is
          # fatal, because ClientHealth.init/1 queries
          # download_client_configs synchronously, and the failure leaves
          # fresh worktrees unmigrated forever rather than retrying. It needs
          # the repo and nothing else.
          echo "==> Pre-migration backup task"
          if grep -vE '^[[:space:]]*#' lib/mix/tasks/mydia.backup_before_migrate.ex | grep -nE 'app\.start'; then
            echo "::error::mydia.backup_before_migrate must not start the application; use Ecto.Migrator.with_repo/2"
            FAIL=1
          fi

          # Shell entry must not boot the app or start a service. mydia:ecto
          # does both: it runs the backup task and, under Postgres, needs a
          # live server. Attaching it to enterShell is what made every fresh
          # worktree fail on entry and what spawned a second postmaster
          # beside `./dev up -d`. It belongs to processes.phoenix.after and
          # `./dev db.setup`, and nothing else stops someone deleting that
          # `after`, which would silently restore the original crash
          # (phoenix booting against an unmigrated database) with CI green,
          # so the positive invariant is guarded too.
          echo "==> Shell-entry purity"
          BLOCK=$(awk '/"mydia:ecto" = \{/,/^    \};/' devenv.nix | grep -vE '^[[:space:]]*#' || true)
          if [ -z "$BLOCK" ]; then
            echo "::error::guard could not locate the mydia:ecto block in devenv.nix"
            FAIL=1
          else
            if echo "$BLOCK" | grep -n 'before = onEnterShell'; then
              echo "::error::mydia:ecto must not run on shell entry; it belongs to processes.phoenix.after"
              FAIL=1
            fi
            if echo "$BLOCK" | grep -n 'devenv:processes:postgres'; then
              echo "::error::mydia:ecto must not depend on the postgres process; a task dependency starts a second postmaster"
              FAIL=1
            fi
          fi
          # Full-line comments dropped, so a commented-out `after` fails.
          if ! grep -vE '^[[:space:]]*#' devenv.nix \
            | grep -q 'processes\.phoenix\.after = \[ "mydia:ecto@succeeded" \]'; then
            echo "::error::phoenix must wait for mydia:ecto@succeeded, or it boots against an unmigrated database"
            FAIL=1
          fi

          exit "$FAIL"
        '';
      };

      # The two lists, one directory per line, compared as sorted text.
      # server/ is not in the script's glob and is left out of rust.nix's
      # side; it is a workspace with checks of its own.
      ciChecks.ci-crate-list = check {
        name = "ci-crate-list";
        set = fs.unions [
          (root + "/scripts/check-rust.sh")
          (fs.fileFilter (f: f.name == "Cargo.toml") (root + "/native"))
          (fs.fileFilter (f: f.name == "Cargo.toml") (root + "/player/rust"))
        ];
        script = ''
          bash scripts/check-rust.sh --list | sort > "$TMPDIR/script"
          sort ${nixCrateList} > "$TMPDIR/nix"
          if ! diff -u --label scripts/check-rust.sh "$TMPDIR/script" \
            --label nix/ci/rust.nix "$TMPDIR/nix"; then
            echo "::error::scripts/check-rust.sh and nix/ci/rust.nix list different crates (lines above: - only in the script's glob, + only in rust.nix). Add the crate to the crates list in nix/ci/rust.nix, or remove the stale entry."
            exit 1
          fi
          echo "scripts/check-rust.sh and nix/ci/rust.nix agree on $(wc -l < "$TMPDIR/script") crates"
        '';
      };
    };
}
