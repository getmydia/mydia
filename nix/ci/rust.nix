# Rust checks, NIFs and bundled plugin wasm, built with crane.
#
# Replaces the old CI `Rust` job (scripts/check-rust.sh, check-plugins.sh,
# test-plugins.sh, the per-crate `cargo test` steps and the p2p core's wasm
# build) and ci-server.yml, with the same commands and flags.
#
# Every crate gets three checks, `rust-<name>-fmt`, `-clippy` and `-test`,
# sharing one dependency build (`buildDepsOnly`). They run cargo's default
# profile, as plain `cargo clippy` and `cargo test` do. The NIFs and plugin
# guests are release builds, as Rustler (prod) and the plugins Mix compiler
# make them, so they have their own release dependency builds.
#
# The crate list below mirrors the manifest globs in scripts/check-rust.sh
# (native/* minus cardigann_guest, plus player/rust/*); a new crate needs an
# entry here.
{ ... }:

{
  perSystem = { pkgs, lib, ci, ... }:
    let
      inherit (ci) sources craneLib;
      fs = lib.fileset;
      root = ../..;

      # A crate's common crane arguments. `src` is the crate's file set, rooted
      # at the repo so path dependencies resolve; the build runs in `dir`.
      crateArgs = { name, dir, set, profile }: {
        pname = "ci-${name}";
        version = "0";
        src = sources.toSource set;
        cargoLock = root + "/${dir}/Cargo.lock";
        # The manifest is not at the source root, where crane looks by default.
        cargoToml = root + "/${dir}/Cargo.toml";
        postUnpack = ''
          cd "$sourceRoot/${dir}"
          sourceRoot=.
        '';
        strictDeps = true;
        # "" runs cargo without --profile (dev for build/clippy, test for
        # test), exactly like the plain cargo commands the old CI ran.
        CARGO_PROFILE = profile;
      };

      # fmt, clippy and test for one crate, as `checks`, and the crate's
      # dependency build they share, as `cargoDeps` (exposed in ciInternal so
      # the CI planner builds and pushes it once instead of once per check).
      # `testArgs` and `clippyArgs` are the flags the old CI passed after
      # `cargo test` / `cargo clippy`.
      mkRustChecks =
        { name
        , dir
        , set
        , testArgs ? ""
        , clippyArgs ? "--all-targets --all-features -- -D warnings"
        , fmtArgs ? "--all"
        , extraArgs ? { }
        , testInputs ? [ ]
        , testEnv ? { }
        }:
        let
          common = crateArgs { inherit name dir set; profile = ""; } // extraArgs;
          cargoArtifacts = craneLib.buildDepsOnly common;
        in
        {
          cargoDeps = cargoArtifacts;
          checks = {
            "rust-${name}-fmt" = craneLib.cargoFmt (common // {
              cargoExtraArgs = fmtArgs;
            });

            "rust-${name}-clippy" = craneLib.cargoClippy (common // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = clippyArgs;
              doInstallCargoArtifacts = false;
            });

            # The test log is the output, so a cached result is still readable.
            # mkCargoDerivation rather than cargoTest, which would override the
            # command below.
            "rust-${name}-test" = craneLib.mkCargoDerivation (common // testEnv // {
              inherit cargoArtifacts;
              pnameSuffix = "-test";
              nativeBuildInputs = (common.nativeBuildInputs or [ ]) ++ testInputs;
              buildPhaseCargoCommand = "";
              doCheck = true;
              checkPhaseCargoCommand = ''
                set -o pipefail
                export HOME="$TMPDIR"
                cargoWithProfile test --locked ${testArgs} 2>&1 | tee "$TMPDIR/test.log"
              '';
              doInstallCargoArtifacts = false;
              installPhaseCommand = ''
                mkdir -p $out
                cp "$TMPDIR/test.log" $out/test.log
              '';
            });
          };
        };

      crates = [
        {
          name = "mydia_media_names";
          dir = "native/mydia_media_names";
          set = sources.nativeCrate "mydia_media_names";
        }
        {
          name = "mydia_p2p";
          dir = "native/mydia_p2p";
          set = sources.nativeCrate "mydia_p2p";
        }
        {
          # `test-introspection` exposes only a counter. Without it
          # `two_sends_to_one_unconnected_peer_share_a_dial` is compiled out.
          name = "mydia_p2p_core";
          dir = "native/mydia_p2p_core";
          set = sources.nativeCrate "mydia_p2p_core";
          testArgs = "--features test-introspection";
        }
        {
          name = "mydia_plugin_macros";
          dir = "native/mydia_plugin_macros";
          set = sources.nativeCrate "mydia_plugin_macros";
        }
        {
          name = "mydia_plugin_sdk";
          dir = "native/mydia_plugin_sdk";
          set = sources.nativeCrate "mydia_plugin_sdk";
        }
        {
          name = "mydia_subsync";
          dir = "native/mydia_subsync";
          set = sources.nativeCrate "mydia_subsync";
        }
        {
          # The Samba integration tests need a root smbd
          # (tests/samba/run-samba.sh starts it with sudo), which the sandbox
          # cannot provide. Here, without MYDIA_SMB_TEST_HOST, they report
          # "skipped" and pass, and the unit tests run as before. The
          # integration tests stay in an ordinary ci.yml job that starts the
          # harness and runs with MYDIA_SMB_REQUIRE_HARNESS=1.
          name = "mydia_smb";
          dir = "player/rust/mydia_smb";
          set = sources.playerCrate "mydia_smb";
          testArgs = "--features test-introspection";
        }
        {
          name = "mydia_player_p2p";
          dir = "player/rust/mydia_player_p2p";
          set = sources.playerCrate "mydia_player_p2p";
        }
        {
          # ci-server.yml's commands: no --all-features on clippy, and the
          # playback tests synthesize media with ffmpeg and probe with ffprobe.
          name = "server";
          dir = "server";
          set = sources.server;
          clippyArgs = "--all-targets -- -D warnings";
          testArgs = "--all";
          testInputs = [ pkgs.ffmpeg-headless ];
        }
      ];

      crateBuilds = map (c: { inherit (c) name; } // mkRustChecks c) crates;
      crateChecks = lib.foldl' (acc: b: acc // b.checks) { } crateBuilds;
      crateDeps = lib.listToAttrs (map (b: lib.nameValuePair "cargoDeps-${b.name}" b.cargoDeps) crateBuilds);

      # The p2p core's browser build. `--no-default-features` drops `host`, so
      # the host-target clippy above never sees this cfg path. ring compiles C
      # through cc-rs, which needs an unwrapped clang and llvm-ar for wasm32
      # (the nix cc wrappers inject host flags clang rejects; see devenv.nix).
      p2pCoreWasm =
        let
          wasmFlags = "--locked --target wasm32-unknown-unknown --no-default-features";
          common = crateArgs {
            name = "mydia_p2p_core-wasm";
            dir = "native/mydia_p2p_core";
            set = sources.nativeCrate "mydia_p2p_core";
            profile = "";
          } // {
            cargoExtraArgs = wasmFlags;
            doCheck = false;
            CC_wasm32_unknown_unknown = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
            AR_wasm32_unknown_unknown = "${pkgs.llvmPackages.llvm}/bin/llvm-ar";
          };
          cargoArtifacts = craneLib.buildDepsOnly common;
        in
        craneLib.mkCargoDerivation (common // {
          inherit cargoArtifacts;
          pnameSuffix = "-check";
          buildPhaseCargoCommand = ''
            cargoWithProfile build ${wasmFlags}
            cargoWithProfile clippy ${wasmFlags} -- -D warnings
          '';
          doInstallCargoArtifacts = false;
        });

      # Every plugin lock, vendored together for the script-driven check.
      pluginLocks =
        map (n: root + "/plugins/${n}/Cargo.lock") bundledPlugins
        ++ map (n: root + "/plugins-extra/${n}/Cargo.lock") extraPlugins;

      cratesIn = dir: builtins.attrNames (lib.filterAttrs
        (n: type: type == "directory" && builtins.pathExists (root + "/${dir}/${n}/Cargo.toml"))
        (builtins.readDir (root + "/${dir}")));
      bundledPlugins = cratesIn "plugins";
      extraPlugins = cratesIn "plugins-extra";

      # scripts/check-plugins.sh (fmt + clippy for wasm32-wasip2) and
      # scripts/test-plugins.sh (host cargo test plus Node tests), run as is
      # over plugins/ and plugins-extra/ with every lock vendored.
      rustPlugins = craneLib.mkCargoDerivation {
        pname = "ci-plugins";
        version = "0";
        src = sources.toSource (fs.unions [
          sources.plugins
          sources.pluginsExtra
          (root + "/scripts/check-plugins.sh")
          (root + "/scripts/test-plugins.sh")
        ]);
        strictDeps = true;
        cargoArtifacts = null;
        cargoVendorDir = craneLib.vendorMultipleCargoDeps { cargoLockList = pluginLocks; };
        nativeBuildInputs = [ pkgs.nodejs ];
        # Each crate builds into its own target/, as it does outside Nix.
        preBuild = ''
          unset CARGO_TARGET_DIR
          export HOME="$TMPDIR"
        '';
        buildPhaseCargoCommand = ''
          bash scripts/check-plugins.sh
          bash scripts/test-plugins.sh
        '';
        doInstallCargoArtifacts = false;
      };

      # One bundled plugin guest, as lib/mix/tasks/compile/plugins.ex builds
      # it: `cargo build --release --target wasm32-wasip2` in the crate dir.
      mkPluginWasm = name:
        let
          common = crateArgs {
            name = "plugin-${name}";
            dir = "plugins/${name}";
            set = sources.plugins;
            profile = "release";
          } // {
            cargoExtraArgs = "--locked --target wasm32-wasip2";
            doCheck = false;
          };
        in
        craneLib.buildPackage (common // {
          cargoArtifacts = craneLib.buildDepsOnly common;
          installPhaseCommand = ''
            mkdir -p $out
            cp target/wasm32-wasip2/release/${name}.wasm $out/
          '';
        });

      pluginWasm = pkgs.runCommand "ci-plugin-wasm" { } ''
        mkdir -p $out
        ${lib.concatMapStrings (n: ''
          cp ${mkPluginWasm n}/${n}.wasm $out/
        '') bundledPlugins}
      '';

      # A Rustler NIF, release profile, at lib/lib<crate>.so.
      mkNif = name:
        let
          common = crateArgs {
            name = "nif-${name}";
            dir = "native/${name}";
            set = sources.nativeCrate name;
            profile = "release";
          } // {
            cargoExtraArgs = "--locked --lib";
            doCheck = false;
          };
        in
        craneLib.buildPackage (common // {
          cargoArtifacts = craneLib.buildDepsOnly common;
          installPhaseCommand = ''
            mkdir -p $out/lib
            # Rustler names the NIF .so on every platform.
            cp target/release/lib${name}${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} \
              $out/lib/lib${name}.so
          '';
        });

      rustChecks = crateChecks // {
        rust-p2p-core-wasm = p2pCoreWasm;
        rust-plugins = rustPlugins;
      };
    in
    {
      checks = rustChecks;

      ciRustAttrs = builtins.attrNames rustChecks;

      ciInternal = crateDeps // {
        nifs-mydia_p2p = mkNif "mydia_p2p";
        nifs-mydia_subsync = mkNif "mydia_subsync";
        inherit pluginWasm;
      };
    };
}
