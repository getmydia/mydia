# metadata-relay: its own Mix project, on its own BEAM pair.
#
#   relayDepsCompiled   deps/ plus _build/test/lib/<dep> from
#                       `MIX_ENV=test mix deps.compile`, offline, from
#                       metadata-relay/deps.nix (mix2nix of its mix.lock).
#                       ciInternal.relayDepsCompiled.
#   relay-test          the old `Relay / Test` job (ci-relay.yml):
#                       `deps.unlock --check-unused`, `compile
#                       --warnings-as-errors`, `format --check-formatted`,
#                       `ecto.create && ecto.migrate`, `test
#                       --warnings-as-errors`, with --seed 0. The log is
#                       $out/test.log.
#   ciRelay             _module.args: the BEAM package set and deps.nix
#                       (prod: no lazy_html) for packages.metadata-relay's
#                       mixRelease in nix/packages/flake-module.nix.
#
# The toolchain is the pair metadata-relay/.elixir-version and
# metadata-relay/.otp-version pin (through beam-version.nix), the one
# ci-relay.yml set up, not the app's.
#
# The database is SQLite: config/test.exs puts it at
# metadata-relay/metadata_relay_test.db. REDIS_URL is unset, so the relay
# uses its in-memory cache and the Redis tests take their no-Redis branch,
# as on the old runner.
#
# Same layout rule as nix/ci/elixir.nix: both derivations unpack the repo
# file set at /build/source and work in /build/source/metadata-relay, where
# the deps' build manifests point, and copies keep timestamps so Mix sees
# nothing stale. There are no git deps, so the Hex deps pass Mix's deps
# check as they are; --no-deps-check is passed anyway, as for the app.
{ ... }:

{
  perSystem = { pkgs, lib, ci, ... }:
    let
      relayDir = ../../metadata-relay;
      at = path: relayDir + "/${path}";

      mixLib = import ./mix-lib.nix { inherit pkgs lib; };

      beamPin = import ../../beam-version.nix { inherit pkgs; dir = relayDir; };
      beamPackages = beamPin.beam.overrideScope (_final: _prev: {
        elixir = beamPin.elixir;
      });

      # Only lexborPrepare is used: lazy_html pins the same lexbor revision
      # in both projects. A lazy_html bump that moves it fails the build at
      # the Makefile's `git fetch`, which has no network.
      inherit (import ../beam-deps.nix {
        inherit pkgs beamPackages;
        inherit (ci) rustToolchain;
      }) lexborPrepare;

      mixNixDeps = import (at "deps.nix") { inherit lib beamPackages; };
      lockHex = mixLib.lockHex (at "mix.lock");
      assertFresh = mixLib.assertFresh {
        lock = lockHex;
        inherit mixNixDeps;
        depsFile = "metadata-relay/deps.nix";
        lockFile = "metadata-relay/mix.lock";
      };

      # The same deps.nix for packages.metadata-relay's mixRelease
      # (nix/packages/flake-module.nix), in prod: lazy_html is test-only and
      # needs lexbor, so it is dropped, including from phoenix_live_view's
      # beamDeps (an optional dependency there), and exqlite's elixir_make
      # gets a writable cache, as the app's override in nix/beam-deps.nix.
      releaseMixNixDeps = builtins.removeAttrs
        (import (at "deps.nix") {
          inherit lib beamPackages;
          overrides = _final: prev: {
            exqlite = prev.exqlite.override {
              buildInputs = [ pkgs.sqlite ];
              preBuild = ''
                export HOME=/tmp
                mkdir -p /tmp/.cache/elixir_make
              '';
            };
            phoenix_live_view = prev.phoenix_live_view.override (old: {
              beamDeps = lib.remove prev.lazy_html old.beamDeps;
            });
          };
        }) [ "lazy_html" ];

      inherit (ci.sources) toSource relayProject relayTest;

      env = mixLib.mixEnv beamPackages;
      nativeBuildInputs = [ beamPackages.erlang beamPackages.elixir ];

      enterProject = ''
        if [ "$PWD" != /build/source ]; then
          echo "expected to run in /build/source (relayDepsCompiled's manifests point there), got $PWD" >&2
          exit 1
        fi
        cd metadata-relay
      '';

      relayDepsSrc = pkgs.runCommand "relay-mix-deps-src" { } ''
        mkdir -p $out
        ${lib.concatMapStrings (name: ''
          cp -r ${mixNixDeps.${name}.src} $out/${name}
        '') (builtins.attrNames lockHex)}
        chmod -R u+w $out
      '';

      relayDepsCompiled = pkgs.stdenv.mkDerivation {
        pname = "relay-mix-deps-compiled";
        version = "0";
        src = toSource relayProject;

        nativeBuildInputs = nativeBuildInputs ++ [ pkgs.cmake pkgs.gnumake ];
        buildInputs = [ pkgs.sqlite ];

        dontUseCmakeConfigure = true;
        dontConfigure = true;
        # NIFs keep their symbols.
        dontStrip = true;

        env = env // { ERL_COMPILER_OPTIONS = "[deterministic]"; };

        buildPhase = ''
          runHook preBuild
          ${mixLib.setupHome}
          mkdir -p $HOME/.cache/elixir_make
          ${enterProject}

          cp -r ${relayDepsSrc} deps
          chmod -R u+w deps

          ${mixLib.nifSourceEdits lexborPrepare}
          mix deps.compile

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          # Build intermediates: lazy_html's lexbor tree. `metadata_relay`
          # holds only the compile lock deps.compile left.
          rm -rf deps/lazy_html/_build _build/test/lib/metadata_relay

          mkdir -p $out/_build/test
          cp -r deps $out/deps
          cp -r _build/test/lib $out/_build/test/lib

          runHook postInstall
        '';
      };

      relayTestCheck = mixLib.mkLogCheck {
        name = "relay-test";
        src = toSource relayTest;
        inherit env nativeBuildInputs;
        log = "test.log";
        script = ''
          ${enterProject}
          cp -r --preserve=timestamps ${relayDepsCompiled}/deps deps
          mkdir -p _build/test
          cp -r --preserve=timestamps ${relayDepsCompiled}/_build/test/lib _build/test/lib
          chmod -R u+w deps _build

          mix deps.unlock --check-unused
          mix compile --warnings-as-errors --no-deps-check
          mix format --check-formatted
          mix do ecto.create --no-deps-check + ecto.migrate --no-deps-check
          mix test --warnings-as-errors --seed 0 --no-deps-check
        '';
      };
    in
    {
      # The relay's BEAM pair and release deps, for packages.metadata-relay.
      _module.args.ciRelay = {
        inherit beamPackages;
        mixNixDeps = assertFresh releaseMixNixDeps;
      };

      # Evaluating `checks` trips the freshness assertion, as for the app's
      # deps.nix in nix/ci/mix-deps.nix.
      ciChecks = assertFresh {
        relay-test = relayTestCheck;
      };

      ciInternal.relayDepsCompiled = assertFresh relayDepsCompiled;
    };
}
