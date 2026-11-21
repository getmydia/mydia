# The ExUnit suite as sandboxed shards, on top of mydiaTestBuild.
#
#   test-sqlite-{1..4}    `mix test --partitions 4`, SQLite (max_cases 1)
#   test-postgres-{1..3}  `mix test --partitions 3`, PostgreSQL
#   ci-cardigann-hash     the shards' Cardigann guest source hash equals
#                         `mix mydia.cardigann_guest hash`
#
# The shards carry the Cardigann guest pinned in
# native/cardigann_guest/ARTIFACT_SHA256, so the :cardigann_wasm tests run
# while that pin matches the guest sources.
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

      # The Cardigann wasm guest, pinned by native/cardigann_guest/ARTIFACT_SHA256
      # ("<source hash> <sha256>"), the same pin the app compiles in to verify
      # the guest it downloads (Mydia.Indexers.Cardigann.Wasm.Artifact). The
      # shards install it only while the pin's source hash is the hash of the
      # guest sources in this tree; otherwise it is absent and test_helper.exs
      # excludes :cardigann_wasm, loudly. Bumping ARTIFACT_SHA256 to a
      # published guest is what turns those tests on.
      #
      # The sources' hash is computed at build time, in cardigannSourceHash,
      # not at eval time: it is SHA-256 over `path <> <<0>> <> contents` per
      # file, and a Nix string cannot hold a NUL byte, so builtins.hashString
      # cannot reproduce it. cardigannSourceHash runs the repo's own
      # native/cardigann_guest/scripts/source-hash.sh instead, and the
      # ci-cardigann-hash check proves it equals `mix mydia.cardigann_guest
      # hash`, the value the compiled Artifact module names its file by.
      cardigannPinFile = builtins.readFile (root + "/native/cardigann_guest/ARTIFACT_SHA256");
      cardigannPinMatch = builtins.match "([0-9a-f]{16})[[:space:]]+([0-9a-f]{64})[[:space:]]*" cardigannPinFile;
      cardigannPin =
        assert lib.assertMsg (cardigannPinMatch != null)
          "nix/ci/tests.nix: native/cardigann_guest/ARTIFACT_SHA256 is not \"<16-hex source hash> <64-hex sha256>\"";
        {
          sourceHash = builtins.elemAt cardigannPinMatch 0;
          sha256 = builtins.elemAt cardigannPinMatch 1;
        };

      # Artifact's @default_base_url and file_name/0: the release
      # cardigann-guest-<hash>, asset cardigann-<hash>.wasm.
      cardigannGuest = pkgs.fetchurl {
        name = "cardigann-${cardigannPin.sourceHash}.wasm";
        url = "https://github.com/getmydia/mydia/releases/download/cardigann-guest-${cardigannPin.sourceHash}/cardigann-${cardigannPin.sourceHash}.wasm";
        inherit (cardigannPin) sha256;
      };

      # The script lists files with `git ls-files`. A flake source holds
      # exactly the tracked files, so an index of all of them is the
      # checkout's; -f keeps a tracked file that .gitignore matches.
      cardigannSourceHash = pkgs.runCommand "cardigann-source-hash"
        {
          src = sources.toSource (root + "/native/cardigann_guest");
          nativeBuildInputs = [ pkgs.git ];
        }
        ''
          cp -r $src source
          chmod -R u+w source
          cd source
          git init --quiet
          git add -f -- native/cardigann_guest
          bash native/cardigann_guest/scripts/source-hash.sh > $out
        '';

      # Lays the guest where `mix mydia.cardigann_guest fetch` would
      # (Artifact.path/0: _build/test/lib/mydia/priv, Mix's symlink to
      # priv/), with the .sha256 sidecar Artifact.load/1 checks it against.
      installCardigannGuest = ''
        cardigann_hash=$(cat ${cardigannSourceHash})
        if [ "$cardigann_hash" = ${cardigannPin.sourceHash} ]; then
          mkdir -p priv/cardigann
          cp ${cardigannGuest} priv/cardigann/cardigann-$cardigann_hash.wasm
          echo ${cardigannPin.sha256} > priv/cardigann/cardigann-$cardigann_hash.wasm.sha256
          chmod u+w priv/cardigann/cardigann-$cardigann_hash.wasm*
        else
          echo "Cardigann guest pin (native/cardigann_guest/ARTIFACT_SHA256) is for ${cardigannPin.sourceHash}, these sources hash to $cardigann_hash: not installing it"
        fi
      '';

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
          # test/ without its Markdown (no test reads a .md under test/), so a
          # doc edit there does not rerun the shards.
          set = lib.fileset.unions [
            buildSet
            (lib.fileset.difference sources.elixirTest
              (lib.fileset.fileFilter (file: file.hasExt "md") sources.elixirTest))
            testReads
          ];
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
            # A reproducible run shape: the GitHub runner's 4 cores on every
            # machine, so PostgreSQL's max_cases (the schedulers, capped in
            # test_helper.exs) and the async interleaving match CI's.
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
            # of them is the checkout's. That makes artifact_test's walk-vs-git
            # comparison vacuous here; `./dev test` in a real checkout exercises it.
            git init --quiet
            git add -- native/cardigann_guest

            ${installCardigannGuest}

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
      checks = shards "sqlite" 4 // shards "postgres" 3 // {
        # The shards decide whether to install the pinned guest by
        # cardigannSourceHash; the test build names the file it loads by
        # Artifact.source_hash/0. They must agree, or a correct pin would
        # sit unused under the wrong name.
        ci-cardigann-hash = mkCheck {
          name = "ci-cardigann-hash";
          set = buildSet;
          script = ''
            ${copyBuild ciInternal.mydiaTestBuild-sqlite}
            mix_hash=$(mix do loadpaths --no-deps-check + mydia.cardigann_guest hash | tail -n 1)
            nix_hash=$(cat ${cardigannSourceHash})
            echo "mix mydia.cardigann_guest hash: $mix_hash"
            echo "cardigannSourceHash:            $nix_hash"
            if [ "$mix_hash" != "$nix_hash" ]; then
              echo "cardigannSourceHash disagrees with Mydia.Indexers.Cardigann.Wasm.SourceHash" >&2
              exit 1
            fi
          '';
        };
      };

      # Build-time inputs every shard shares. None is in a shard's output
      # closure, so pushing a shard never uploads them; exposed here, the CI
      # planner builds and pushes each once (rustfs is a full Rust build).
      ciInternal = {
        inherit rustfs cardigannGuest cardigannSourceHash;
      };
    };
}
