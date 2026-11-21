# The ExUnit suite as sandboxed shards, on top of mydiaTestBuild.
#
#   test-sqlite-{1..4}    `mix test --partitions 4`, SQLite (max_cases 1)
#   test-postgres-{1..3}  `mix test --partitions 3`, PostgreSQL
#
# Each shard starts its own RustFS (the :s3 tests, MYDIA_TEST_S3_REQUIRED=1
# so a dead server fails the shard) and, for PostgreSQL, its own server, all
# on loopback inside the build's network namespace, so the fixed ports never
# collide between shards. There is no network otherwise: a test that needs
# it is tagged :external (excluded in test/test_helper.exs). ExUnit runs with
# --seed 0, so a cached result is reproducible. The output is test.log.
#
# PostgreSQL listens on localhost:5433 as user postgres, the defaults
# config/test.exs falls back to. test.exs is compile-time config for :mydia,
# and Mix recompiles the whole app when that changes, so pointing
# DATABASE_HOST/PORT/USER anywhere else would throw away mydiaTestBuild.
# DATABASE_NAME is read by config/runtime.exs only.
#
# Every shard reads all of test/, so any test edit reruns all seven.
{ ... }:

{
  perSystem = { pkgs, lib, ci, ciElixir, config, ... }:
    let
      inherit (ci) sources;
      inherit (ciElixir) buildSet copyBuild mkCheck;
      inherit (config) ciInternal;

      # devenv.nix's RustFS, same override (so the same store path).
      rustfs = pkgs.rustfs.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.pkg-config ];
        buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.aws-lc pkgs.zstd ];
        env = (old.env or { }) // {
          CARGO_PROFILE_RELEASE_LTO = "false";
          CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
        };
      });

      postgresql = pkgs.postgresql_17;

      root = ../..;

      # Files outside the app and test/ that tests read: parity and guard
      # tests over CSS, workflows, scripts, the BEAM and gluetun pins, the
      # player's tables and GraphQL documents, and the Nix Wasmex lock. A test
      # that reads a repo file missing here fails with :enoent, not a skip;
      # plugins-extra is also globbed at compile time, one test per manifest.
      testReads = lib.fileset.unions [
        sources.pluginsExtra
        (root + "/.elixir-version")
        (root + "/.otp-version")
        (root + "/vendor/gluetun/VERSION")
        (root + "/.github/workflows")
        (root + "/assets/css")
        (root + "/docker/vpn-preflight.sh")
        (root + "/scripts/build_plugin_index.exs")
        (root + "/scripts/harvest_sonarr_fixtures.exs")
        (root + "/player/lib/core/language/language_equivalents.dart")
        (root + "/player/lib/graphql")
        (root + "/nix/wasmex-Cargo.lock")
      ];

      # devenv.nix's MYDIA_TEST_S3_* (on a fixed port: the sandbox has its
      # own loopback).
      s3Env = {
        MYDIA_TEST_S3_ENDPOINT = "http://127.0.0.1:9000";
        MYDIA_TEST_S3_ACCESS_KEY_ID = "mydia";
        MYDIA_TEST_S3_SECRET_ACCESS_KEY = "mydia-dev-secret";
        MYDIA_TEST_S3_BUCKET = "mydia-test";
        MYDIA_TEST_S3_REQUIRED = "1";
      };

      startRustfs = ''
        mkdir -p $TMPDIR/rustfs
        rustfs server \
          --address 127.0.0.1:9000 \
          --access-key "$MYDIA_TEST_S3_ACCESS_KEY_ID" \
          --secret-key "$MYDIA_TEST_S3_SECRET_ACCESS_KEY" \
          $TMPDIR/rustfs > $TMPDIR/rustfs.log 2>&1 &
        rustfs_pid=$!
        for _ in $(seq 1 60); do
          curl -s -o /dev/null "$MYDIA_TEST_S3_ENDPOINT" && break
          sleep 1
        done
        if ! curl -s -o /dev/null "$MYDIA_TEST_S3_ENDPOINT"; then
          echo "RustFS did not answer at $MYDIA_TEST_S3_ENDPOINT" >&2
          cat $TMPDIR/rustfs.log >&2
          exit 1
        fi
      '';

      startPostgres = ''
        mkdir -p $TMPDIR/pg
        initdb --pgdata=$TMPDIR/pg/data --username=postgres --auth=trust \
          --encoding=UTF8 --no-locale > $TMPDIR/pg/initdb.log
        pg_started=1
        if ! pg_ctl --pgdata=$TMPDIR/pg/data --log=$TMPDIR/pg/postgres.log --wait \
          --options="-h 127.0.0.1 -p 5433 -k $TMPDIR/pg" start; then
          cat $TMPDIR/pg/postgres.log >&2
          exit 1
        fi
      '';

      stopServices = ''
        cleanup() {
          if [ -n "''${rustfs_pid:-}" ]; then kill "$rustfs_pid" 2>/dev/null || true; fi
          if [ -n "''${pg_started:-}" ]; then
            pg_ctl --pgdata=$TMPDIR/pg/data --mode=immediate stop > /dev/null 2>&1 || true
          fi
        }
        trap cleanup EXIT
      '';

      mkShard = { databaseType, partitions, partition }:
        let
          postgres = databaseType == "postgres";
        in
        mkCheck {
          name = "test-${databaseType}-${toString partition}";
          set = lib.fileset.unions [ buildSet sources.elixirTest testReads ];
          # Tools untagged tests run, all in devenv.nix's packages: ffmpeg
          # and ffprobe (Mydia.Library.Ffmpeg, media fixtures), fpcalc
          # (chromaprint, segment detection), pkill (procps, the ffprobe
          # zombie test) and git (the Cardigann guest source hash).
          inputs = [
            rustfs
            pkgs.curl
            pkgs.ffmpeg
            pkgs.chromaprint
            pkgs.procps
            pkgs.git
          ] ++ lib.optional postgres postgresql;
          log = "test.log";
          extraEnv = s3Env // {
            MIX_TEST_PARTITION = toString partition;
            # There is no /etc/ssl in the sandbox; test/test_helper.exs loads
            # this into OTP's trust store.
            SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            # test_helper.exs runs PostgreSQL with max_cases equal to the
            # schedulers, against a pool of 10 (config/test.exs). Pinned at
            # the GitHub runner's 4 cores, so a large machine does not queue
            # past the pool's timeout and every machine runs the same shape.
            ERL_FLAGS = "+S 4";
          } // lib.optionalAttrs postgres {
            DATABASE_TYPE = "postgres";
            DATABASE_NAME = "mydia_test";
          };
          script = ''
            ${copyBuild ciInternal."mydiaTestBuild-${databaseType}"}
            ${stopServices}
            ${startRustfs}
            ${lib.optionalString postgres startPostgres}

            # Mydia.Indexers.Cardigann.Wasm.SourceHash and its shell twin list
            # the guest's files with `git ls-files`. The sandbox holds exactly
            # the tracked files (a flake source is the git tree), so an index
            # of them is the checkout's.
            git init --quiet
            git add -- native/cardigann_guest

            mix do loadpaths --no-deps-check + ecto.create + ecto.migrate
            ${lib.optionalString postgres "mix do loadpaths --no-deps-check + ecto.migrations"}
            mix do loadpaths --no-deps-check + test \
              --partitions ${toString partitions} --warnings-as-errors --seed 0
          '';
        };

      shards = databaseType: partitions:
        lib.listToAttrs (map
          (partition: {
            name = "test-${databaseType}-${toString partition}";
            value = mkShard { inherit databaseType partitions partition; };
          })
          (lib.range 1 partitions));
    in
    {
      checks = shards "sqlite" 4 // shards "postgres" 3;
    };
}
