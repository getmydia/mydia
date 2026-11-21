# Helpers shared by the Mix projects' CI derivations: the app's
# (nix/ci/mix-deps.nix, nix/ci/elixir.nix) and metadata-relay's
# (nix/ci/relay.nix). Plain functions of pkgs and lib, imported directly.
{ pkgs, lib }:

rec {
  # Hex packages in a mix.lock, { name = version; }. One lock entry per line;
  # git deps are not Hex entries and mix2nix skips them.
  lockHex = lockFile: lib.listToAttrs (lib.concatMap
    (line:
      let
        m = builtins.match
          ''[[:space:]]*"([a-zA-Z0-9_]+)": \{:hex, :[a-zA-Z0-9_]+, "([^"]+)",.*"hexpm", "([^"]+)"}.*''
          line;
      in
      lib.optional (m != null) { name = builtins.elemAt m 0; value = builtins.elemAt m 1; })
    (lib.splitString "\n" (builtins.readFile lockFile)));

  # Freshness: every Hex package in mix.lock needs a deps.nix entry of the
  # same version. Same rule as scripts/check-generated-freshness.sh. Returns
  # a function that passes its argument through, or throws naming the stale
  # packages and the mix2nix command that regenerates `depsFile`.
  assertFresh = { lock, mixNixDeps, depsFile, lockFile }:
    let
      stale = lib.filter
        (name: !(mixNixDeps ? ${name}) || mixNixDeps.${name}.version != lock.${name})
        (builtins.attrNames lock);
    in
    lib.throwIf (stale != [ ])
      "${depsFile} is stale: run mix2nix ${lockFile} > ${depsFile} (missing: ${lib.concatStringsSep ", " stale})";

  # The environment every offline test-env Mix run starts from.
  mixEnv = beamPackages: {
    MIX_ENV = "test";
    HEX_OFFLINE = "1";
    MIX_REBAR3 = "${beamPackages.rebar3}/bin/rebar3";
    # Mix needs Hex loaded to resolve the :hex deps; HEX_OFFLINE keeps it
    # from fetching.
    ERL_LIBS = "${beamPackages.hex}/lib/erlang/lib";
    LANG = "C.UTF-8";
    LC_CTYPE = "C.UTF-8";
  };

  # HOME for Mix and Hex, writable, in the sandbox.
  setupHome = ''
    export HOME=$TMPDIR/home
    export MIX_HOME=$HOME/.mix HEX_HOME=$HOME/.hex
    mkdir -p $HOME
  '';

  # Sandbox-only edits to the elixir_make NIF deps (exqlite, lazy_html), run
  # in the project root after deps/ is in place. Each is --replace-fail, so a
  # dependency bump that moves the line stops here rather than silently
  # trying the network.
  nifSourceEdits = lexborPrepare: ''
    # Build the elixir_make NIFs from source instead of trying their
    # precompiled downloads. exqlite reads this from its app env and
    # lazy_html has no switch, so set the elixir_make option directly.
    # lazy_html's Makefile would also `git clone` lexbor.
    substituteInPlace deps/exqlite/mix.exs --replace-fail \
      'make_force_build: Application.get_env(:exqlite, :force_build, false),' \
      'make_force_build: true,'
    substituteInPlace deps/lazy_html/mix.exs --replace-fail \
      'make_precompiler: {:nif, CCPrecompiler},' \
      'make_force_build: true, make_precompiler: {:nif, CCPrecompiler},'
    pushd deps/lazy_html >/dev/null
    ${lexborPrepare}
    popd >/dev/null
  '';

  # A check whose output is its log ($out/<log>), so a cached result stays
  # readable.
  mkLogCheck = { name, src, env, nativeBuildInputs, script, log ? "log" }:
    pkgs.stdenv.mkDerivation {
      inherit name env src nativeBuildInputs;
      dontConfigure = true;
      dontInstall = true;
      buildPhase = ''
        runHook preBuild
        ${setupHome}
        mkdir -p $out
        (
          set -euo pipefail
          ${script}
        ) 2>&1 | tee $out/${log}
        test "''${PIPESTATUS[0]}" = 0
        runHook postBuild
      '';
    };
}
