# The app's test-env build and the Elixir lint checks.
#
#   mydiaTestBuild    `mix compile --warnings-as-errors` of the app in the
#                     test env, on top of mixDepsCompiled, with the NIFs and
#                     plugin wasm from nix/ci/rust.nix (MYDIA_PREBUILT_NIFS=1,
#                     MYDIA_PREBUILT_PLUGINS=1, so no cargo runs). Exposed as
#                     ciInternal.mydiaTestBuild-{sqlite,postgres}.
#   dialyzer-plt      the Dialyzer PLTs (core and deps), keyed on the compiled
#                     deps and the toolchain only, so an app edit reuses it.
#                     ciInternal.dialyzer-plt.
#   elixir-format     `mix format --check-formatted`.
#   elixir-lint       the Lint job's guard greps, `deps.unlock --check-unused`,
#                     Credo and `gettext.extract --check-up-to-date`.
#   dialyzer          `mix dialyzer --format github` against the test build.
#
# Every derivation runs in /build/source, where mixDepsCompiled was built:
# Mix records absolute paths in the deps' build manifests, so deps/ and
# _build/ sit side by side there. That deps/ is not what `mix deps.get`
# leaves (heroicons has no .git, and nix/ci/mix-deps.nix edits some deps in
# the sandbox), and the deps check fails on heroicons: each Mix invocation
# passes --no-deps-check, or runs `loadpaths --no-deps-check` first in the
# same `mix do` so a task's own loadpaths/compile call is a no-op. Dialyzer
# is the exception, see heroiconsGitStub.
#
# Copies keep timestamps (cp --preserve=timestamps). Store files all have
# mtime 1, so sources, beams and manifests stay older than the time each
# manifest records and Mix sees nothing stale. A plain `cp -r` would date the
# deps' manifests after the app's, and Mix would recompile the whole app.
{ ... }:

{
  perSystem = { pkgs, lib, ci, config, ... }:
    let
      inherit (ci) sources beamPackages;
      fs = lib.fileset;
      root = ../..;
      inherit (config) ciInternal;

      # What the app compile reads beyond elixirApp: test/support
      # (elixirc_paths in the test env) and the Cardigann guest sources,
      # which Mydia.Indexers.Cardigann.Wasm.Artifact hashes at compile time.
      buildSet = fs.unions [
        sources.elixirApp
        sources.gettext
        (root + "/test/support")
        (root + "/native/cardigann_guest")
      ];

      mixLib = import ./mix-lib.nix { inherit pkgs lib; };
      inherit (mixLib) setupHome;

      env = mixLib.mixEnv beamPackages // {
        # The Docker image's switches: load the NIFs from priv/native and the
        # plugin guests from priv/plugins rather than running cargo. Both are
        # set in every derivation that compiles or checks the app, so the
        # compile-time config Mix tracks (Rustler reads :mydia, Mydia.P2p
        # with Application.compile_env) matches the build's.
        MYDIA_PREBUILT_NIFS = "1";
        MYDIA_PREBUILT_PLUGINS = "1";
        # The :cardigann_guest compiler only downloads in the dev env
        # already; this makes the skip explicit, as in the package.
        MYDIA_SKIP_CARDIGANN_FETCH = "1";
      };

      nativeBuildInputs = [ beamPackages.erlang beamPackages.elixir ];

      # deps/ and _build/test/lib/<dep> from mixDepsCompiled, writable.
      copyDeps = deps: ''
        if [ "$PWD" != /build/source ]; then
          echo "expected to run in /build/source (mixDepsCompiled's manifests point there), got $PWD" >&2
          exit 1
        fi
        cp -r --preserve=timestamps ${deps}/deps deps
        mkdir -p _build/test
        cp -r --preserve=timestamps ${deps}/_build/test/lib _build/test/lib
        chmod -R u+w deps _build
      '';

      # The app build (mydiaTestBuild) over the source tree, writable.
      copyBuild = build: ''
        if [ "$PWD" != /build/source ]; then
          echo "expected to run in /build/source (the build's manifests point there), got $PWD" >&2
          exit 1
        fi
        cp -r --preserve=timestamps ${build}/deps deps
        cp -r --preserve=timestamps ${build}/_build _build
        mkdir -p priv/native priv/plugins
        cp --preserve=timestamps ${build}/priv/native/* priv/native/
        cp --preserve=timestamps ${build}/priv/plugins/*.wasm priv/plugins/
        chmod -R u+w deps _build priv
      '';

      # dialyxir runs `Mix.Tasks.Deps.Loadpaths.run([])` itself (in
      # Dialyxir.Project.cons_apps), so --no-deps-check cannot reach it, and
      # the deps check fails on heroicons: a git dep counts as checked out
      # only with a .git whose HEAD and origin match mix.lock. The Hex deps
      # pass the check as they are. This gives deps/heroicons that .git,
      # read from the lock entry (Mix only runs `git config
      # remote.origin.url` and `git rev-parse --verify HEAD` on it).
      heroiconsLock = builtins.match
        ''.*"heroicons": \{:git, "([^"]+)", "([0-9a-f]+)",.*''
        (builtins.replaceStrings [ "\n" ] [ " " ] (builtins.readFile (root + "/mix.lock")));
      heroiconsGitStub =
        assert lib.assertMsg (heroiconsLock != null)
          "nix/ci/elixir.nix: no heroicons git entry in mix.lock";
        ''
          git -C deps/heroicons init --quiet
          git --git-dir=deps/heroicons/.git config remote.origin.url ${builtins.elemAt heroiconsLock 0}
          echo ${builtins.elemAt heroiconsLock 1} > deps/heroicons/.git/HEAD
        '';

      # A check whose output is its log ($out/<log>), so a cached result stays
      # readable. `extraEnv` adds to env; a variable the app's compile-time
      # config reads (DATABASE_TYPE) must match the test build it copies.
      mkCheck = { name, set, script, inputs ? [ ], extraEnv ? { }, log ? "log" }:
        mixLib.mkLogCheck {
          inherit name script log;
          env = env // extraEnv;
          src = sources.toSource set;
          nativeBuildInputs = nativeBuildInputs ++ inputs;
        };

      # `databaseType` matters here, unlike for mixDepsCompiled: DATABASE_TYPE
      # selects :mydia's Repo adapter in config/config.exs and config/test.exs,
      # which the app compiles against.
      mydiaTestBuild = { databaseType ? null }:
        let
          variant = if databaseType == null then "sqlite" else databaseType;
          deps = ciInternal."mixDepsCompiled-${variant}";
        in
        pkgs.stdenv.mkDerivation {
          pname = "mydia-test-build-${variant}";
          version = "0";
          src = sources.toSource buildSet;
          env = env // lib.optionalAttrs (databaseType != null) {
            DATABASE_TYPE = databaseType;
          };
          inherit nativeBuildInputs;
          dontConfigure = true;
          # No fixup: NIFs keep their symbols, as in the package, and the
          # RPATH audit would only print "patchelf: wrong ELF type" for the
          # exqlite object files under _build/test/lib/exqlite/obj.
          dontFixup = true;

          buildPhase = ''
            runHook preBuild
            ${setupHome}
            ${copyDeps deps}

            # Rustler's default load path, priv/native/<crate>.so (no lib
            # prefix), as the Dockerfile copies them.
            mkdir -p priv/native priv/plugins
            cp ${ciInternal.nifs-mydia_p2p}/lib/libmydia_p2p.so priv/native/mydia_p2p.so
            cp ${ciInternal.nifs-mydia_subsync}/lib/libmydia_subsync.so priv/native/mydia_subsync.so
            cp ${ciInternal.pluginWasm}/*.wasm priv/plugins/
            chmod u+w priv/native/* priv/plugins/*.wasm

            mix compile --warnings-as-errors --no-deps-check

            # Rustler's on_load fails the module load when the NIF does not
            # load, so this proves both NIFs load from priv/native. Plain
            # elixir rather than `mix run`, which would evaluate
            # config/runtime.exs and log about it.
            ERL_LIBS=$PWD/_build/test/lib:$ERL_LIBS elixir -e '
              for m <- [Mydia.P2p, Mydia.Subsync] do
                {:module, ^m} = Code.ensure_loaded(m)
                IO.puts("#{inspect(m)}: NIF loaded from #{Application.app_dir(:mydia, "priv/native")}")
              end'

            runHook postBuild
          '';

          # deps/ is carried along so consumers get the matching pair in one
          # copy. _build/test/lib/mydia/priv is Mix's relative symlink to
          # priv/, which consumers provide from their own source plus the
          # priv/native and priv/plugins copied here.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/priv
            cp -r deps $out/deps
            cp -r _build $out/_build
            cp -r priv/native $out/priv/native
            mkdir -p $out/priv/plugins
            cp priv/plugins/*.wasm $out/priv/plugins/
            runHook postInstall
          '';
        };

      testBuildSqlite = mydiaTestBuild { };

      # mix.exs `dialyzer:` puts both PLTs in priv/plts. The deps PLT lists
      # :mydia's applications, which dialyxir reads from mydia.app after
      # running `compile`. The source here has no lib/, so that compile
      # writes a mydia.app with the real applications (from mix.exs) and
      # none of the app's modules: the PLT holds the deps and core apps, and
      # an edit under lib/ does not rebuild it. The `dialyzer` check analyzes
      # the app's beams itself; dialyxir only checks the PLT against the lock
      # and the application list, which match there.
      #
      # The project's compiler list names :plugins and :cardigann_guest,
      # whose task modules are compiled from lib/mix/tasks/compile/ into the
      # app's ebin. No-op stand-ins go to the same place: compile.all prunes
      # every other code path (MIX_PATH, -pa) before it looks the compilers
      # up. They are the only :mydia modules in the PLT, and the real ones
      # replace them when the `dialyzer` check analyzes the app, as every
      # other app module in the PLT the old CI cached did.
      #
      # The log carries some 30 "xmerl_ucs.erl: Warning: missing
      # specification" lines while the deps PLT adds OTP's xmerl. They are
      # OTP's own (dialyzer replays the compile options xmerl was built
      # with), are not findings, and do not fail the build.
      compilerStubs = pkgs.writeText "mix-compiler-stubs.ex" ''
        defmodule Mix.Tasks.Compile.Plugins do
          use Mix.Task.Compiler
          @impl true
          def run(_argv), do: {:noop, []}
        end

        defmodule Mix.Tasks.Compile.CardigannGuest do
          use Mix.Task.Compiler
          @impl true
          def run(_argv), do: {:noop, []}
        end
      '';

      dialyzerPlt = pkgs.stdenv.mkDerivation {
        pname = "dialyzer-plt";
        version = "0";
        src = sources.toSource sources.mixProject;
        inherit env;
        nativeBuildInputs = nativeBuildInputs ++ [ pkgs.git ];
        dontConfigure = true;

        buildPhase = ''
          runHook preBuild
          ${setupHome}
          ${copyDeps ciInternal.mixDepsCompiled-sqlite}
          ${heroiconsGitStub}

          mkdir -p _build/test/lib/mydia/ebin
          elixirc -o _build/test/lib/mydia/ebin ${compilerStubs}

          mix do deps.loadpaths --no-deps-check + dialyzer --plt

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          cp -r priv/plts $out
          runHook postInstall
        '';
      };

      lintSet = fs.unions [
        buildSet
        sources.elixirTest
        # The guard below fails when this file exists, so it has to reach the
        # sandbox when it does.
        (fs.maybeMissing (root + "/.dialyzer_ignore.exs"))
      ];
    in
    {
      # For the checks that run on top of the test build (nix/ci/tests.nix),
      # and `env` for devShells.ci (nix/ci/flake-module.nix), which runs Mix
      # over a copy of that build outside the sandbox.
      # heroiconsGitStub for checks that run Mix tasks without
      # --no-deps-check (e2e-browser runs scripts/run-feature-tests.sh as is).
      _module.args.ciElixir = { inherit buildSet copyBuild mkCheck env heroiconsGitStub; };

      ciChecks = {
        # .formatter.exs covers config/, lib/, test/, priv/*/ and the root
        # *.exs files (.credo.ratchet.exs is the one elixirApp lacks); its
        # plugin (Phoenix.LiveView.HTMLFormatter) and import_deps need the
        # deps.
        elixir-format = mkCheck {
          name = "elixir-format";
          set = fs.unions [
            sources.elixirApp
            sources.elixirTest
            (root + "/.credo.ratchet.exs")
          ];
          script = ''
            ${copyDeps ciInternal.mixDepsCompiled-sqlite}
            mix do loadpaths --no-deps-check + format --check-formatted
          '';
        };

        # The Lint job (ci.yml) minus the ratchet and the mix_unused report,
        # which read git history and stay ordinary jobs. The warnings-as-errors
        # compile is mydiaTestBuild-sqlite's. Guard greps verbatim from ci.yml.
        elixir-lint = mkCheck {
          name = "elixir-lint";
          set = lintSet;
          script = ''
            ${copyBuild testBuildSqlite}

            # Guard against re-grandfathering: a Credo check must be enabled-and-
            # gating or `false`, never `exit_status: 0`. See CONTRIBUTING.md.
            if grep -n "exit_status: 0" .credo.exs; then
              echo "::error::exit_status: 0 found in .credo.exs - fix the finding or disable the check with false (see CONTRIBUTING.md)"
              exit 1
            fi
            # Dialyzer findings are fixed, never listed. See "Dialyzer" in
            # CONTRIBUTING.md.
            if grep -n "ignore_warnings" mix.exs; then
              echo "::error::ignore_warnings found in mix.exs - fix the Dialyzer finding instead (see CONTRIBUTING.md)"
              exit 1
            fi
            # Dialyxir reads .dialyzer_ignore.exs by default when it exists, even
            # without ignore_warnings in mix.exs.
            if [ -e .dialyzer_ignore.exs ]; then
              echo "::error::.dialyzer_ignore.exs exists - fix the Dialyzer finding instead (see CONTRIBUTING.md)"
              exit 1
            fi
            if grep -rn "@dialyzer" lib test/support --include='*.ex'; then
              echo "::error::@dialyzer attributes are not allowed in lib/ or test/support - fix the finding instead (see CONTRIBUTING.md)"
              exit 1
            fi
            # Guard against DEPRECATED markers surviving in lib/: deprecated
            # code must be deleted, not left behind under a marker. See
            # CONTRIBUTING.md.
            if grep -rn "DEPRECATED" lib --include='*.ex' --include='*.heex'; then
              echo "::error::DEPRECATED: is not allowed in lib/. Delete the code, or mark it COMPAT: if it is load-bearing backward compatibility. See CONTRIBUTING.md."
              exit 1
            fi

            mix deps.unlock --check-unused
            mix do loadpaths --no-deps-check + credo --strict
            # Fails when a gettext call changed without regenerating
            # priv/gettext/*.pot. `gettext.extract` recompiles the app.
            mix do loadpaths --no-deps-check + gettext.extract --check-up-to-date
          '';
        };

        # The PLT is copied writable to priv/plts, where mix.exs points
        # dialyxir, so a PLT check that repairs it never writes to the store.
        dialyzer = mkCheck {
          name = "dialyzer";
          set = buildSet;
          inputs = [ pkgs.git ];
          script = ''
            ${copyBuild testBuildSqlite}
            ${heroiconsGitStub}
            mkdir -p priv/plts
            cp --preserve=timestamps ${dialyzerPlt}/* priv/plts/
            chmod -R u+w priv/plts
            mix do compile --no-deps-check + dialyzer --format github
          '';
        };
      };

      ciInternal = {
        mydiaTestBuild-sqlite = testBuildSqlite;
        mydiaTestBuild-postgres = mydiaTestBuild { databaseType = "postgres"; };
        dialyzer-plt = dialyzerPlt;
      };
    };
}
