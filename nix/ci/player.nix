# The Flutter player's shared CI inputs, and the helper its checks use.
#
#   player-pub-cache   a PUB_CACHE holding every hosted package in
#                      player/pubspec.lock, from player/pubspec.lock.json
#                      (Nix reads no YAML; scripts/regenerate-derived.sh
#                      writes the JSON and check-generated-freshness.sh
#                      keeps it current). Each archive is fetched by
#                      nixpkgs' pub2nix, the fetcher buildFlutterApplication
#                      uses, so each is fixed-output on the lock's sha256.
#                      ciInternal.player-pub-cache.
#   player-codegen     the repo tree sources.playerCodegen gives, after
#                      `flutter pub get --offline --enforce-lockfile`,
#                      `flutter gen-l10n` and `flutter pub run build_runner build`
#                      in player/: the project with .dart_tool and every
#                      generated Dart file. ciInternal.player-codegen.
#   player-linux       `flutter build linux --release` with the crane-built
#                      p2p library (ciInternal.player-p2p-so, nix/ci/rust.nix)
#                      in place of cargokit's build. Outputs bundle/ and log.
#                      checks.player-linux.
#
# The checks themselves (Tasks 2 onward) are built with
# `ciPlayer.mkPlayerCheck`, which copies player-codegen to /build/source and
# runs its script in /build/source/player, where codegen ran, so the
# absolute paths build_runner recorded under .dart_tool still hold.
#
# Flutter is the package player/flutter-version.nix resolves from
# player/.fvmrc, the single Flutter pin; nothing here names a version.
{ ... }:

{
  perSystem = { pkgs, lib, ci, ciRust, ... }:
    let
      mixLib = import ./mix-lib.nix { inherit pkgs lib; };

      flutter = import ../../player/flutter-version.nix { inherit pkgs; };

      pubspecLock = lib.importJSON ../../player/pubspec.lock.json;

      # Only hosted packages go into the cache. readPubspecLock forces every
      # entry's source to drop nulls, so the path and sdk entries need a src
      # and builders to evaluate; their derivations are never built here
      # (path deps resolve inside the project tree, sdk deps from Flutter).
      lockData = pkgs.pub2nix.readPubspecLock {
        src = ci.sources.toSource ci.sources.playerApp;
        inherit pubspecLock;
        gitHashes = { };
        sdkSourceBuilders = {
          flutter = name: pkgs.runCommand "flutter-sdk-${name}" { passthru.packageRoot = "."; } ''
            ln -s ${flutter}/packages/${name} $out
          '';
        };
      };

      hosted = lib.filterAttrs (_: details: details.source == "hosted") pubspecLock.packages;

      # Pub's cache layout: the extracted package under hosted/<host>/, and
      # the archive's sha256 under hosted-hashes/<host>/, which
      # --enforce-lockfile compares with the lock instead of downloading
      # again. Sources are nixpkgs' (with its Linux patches for a few
      # plugins, as buildFlutterApplication uses them).
      pubCache = pkgs.runCommand "player-pub-cache" { } (''
        mkdir -p $out
      '' + lib.concatStrings (lib.mapAttrsToList
        (name: details:
          let
            host = lib.removePrefix "https://" details.description.url;
            dir = "${details.description.name}-${details.version}";
          in
          ''
            mkdir -p $out/hosted/${host} $out/hosted-hashes/${host}
            cp -r ${lockData.dependencySources.${name}} $out/hosted/${host}/${dir}
            printf '%s' ${details.description.sha256} > $out/hosted-hashes/${host}/${dir}.sha256
          '')
        hosted));

      # Flutter wants a writable HOME and a first-run config; pub and the
      # tool must never reach the network.
      #
      # Pub writes bookkeeping (active_roots/) into PUB_CACHE even offline,
      # so PUB_CACHE is a writable directory whose package trees link to the
      # store. It sits at the same fixed path in player-codegen and every
      # check, because pub writes it into .dart_tool/package_config.json.
      flutterEnv = ''
        export PUB_CACHE=/build/pub-cache
        mkdir -p $PUB_CACHE
        ln -sfn ${pubCache}/hosted $PUB_CACHE/hosted
        ln -sfn ${pubCache}/hosted-hashes $PUB_CACHE/hosted-hashes
        export FLUTTER_SUPPRESS_ANALYTICS=true
        flutter config --no-analytics >/dev/null 2>&1
      '';

      enterPlayer = ''
        if [ "$PWD" != /build/source ]; then
          echo "expected to run in /build/source (player-codegen's paths point there), got $PWD" >&2
          exit 1
        fi
        cd player
      '';

      codegen = pkgs.stdenv.mkDerivation {
        name = "player-codegen";
        src = ci.sources.toSource ci.sources.playerCodegen;
        nativeBuildInputs = [ flutter ];
        dontConfigure = true;
        dontFixup = true;
        buildPhase = ''
          runHook preBuild
          ${mixLib.setupHome}
          ${flutterEnv}
          ${enterPlayer}
          flutter pub get --offline --enforce-lockfile
          flutter gen-l10n
          # `flutter pub run`, as ci-player.yml runs it: a bare `dart run`
          # re-checks the resolution without Flutter's SDK and fails.
          flutter pub run build_runner build --delete-conflicting-outputs
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          cd /build/source
          mkdir -p $out
          cp -a . $out/
          runHook postInstall
        '';
      };

      # `flutter` on a check's PATH: the real one, with two flags added. A
      # PATH shim rather than a shell function, so it also covers runners
      # that call flutter themselves (very_good).
      #
      #   --test-randomize-ordering-seed 0   on every `flutter test` that sets
      #                                      no seed itself: the spec's
      #                                      determinism rule, as phase 1's
      #                                      `mix test --seed 0`
      #   --no-pub                           on test, analyze and build:
      #                                      their implicit `pub get` is not
      #                                      offline, so it version-solves
      #                                      against pub.dev and hangs in the
      #                                      sandbox. player-codegen already
      #                                      resolved the project.
      flutterShim = pkgs.writeShellScriptBin "flutter" ''
        real=${flutter}/bin/flutter
        case "''${1-}" in
          test)
            for arg in "$@"; do
              case $arg in
                --test-randomize-ordering-seed | --test-randomize-ordering-seed=*)
                  exec "$real" "$@" --no-pub ;;
              esac
            done
            exec "$real" "$@" --no-pub --test-randomize-ordering-seed 0 ;;
          analyze | build)
            exec "$real" "$@" --no-pub ;;
        esac
        exec "$real" "$@"
      '';

      # mixLib.mkLogCheck's shape, on a writable copy of player-codegen at
      # /build/source, running `script` in player/ with PUB_CACHE and HOME
      # set, and `flutter` resolving to flutterShim. The output is the log,
      # $out/log.
      mkPlayerCheck = { name, nativeBuildInputs ? [ ], script }:
        (mixLib.mkLogCheck {
          inherit name;
          src = null;
          env = { };
          nativeBuildInputs = [ flutterShim flutter ] ++ nativeBuildInputs;
          script = ''
            mkdir -p /build/source
            cp -a ${codegen}/. /build/source/
            chmod -R u+w /build/source
            cd /build/source
            ${flutterEnv}
            ${enterPlayer}
            ${script}
          '';
        }).overrideAttrs { dontUnpack = true; };

      # `cargo` and `rustup` on player-linux's PATH: both refuse, so a build
      # that falls back to cargokit fails loudly instead of compiling Rust (or
      # trying to download a toolchain) in the sandbox.
      noRustInSandbox = pkgs.runCommand "no-rust-in-sandbox" { } ''
        mkdir -p $out/bin
        for tool in cargo rustup; do
          cat > $out/bin/$tool <<'EOF'
        #!${pkgs.runtimeShell}
        echo "cargokit tried to build Rust in the sandbox ($0 $*)" >&2
        exit 1
        EOF
          chmod +x $out/bin/$tool
        done
      '';

      # Build / Linux: `flutter build linux --release`, with the bundle as
      # $out/bundle and the log as $out/log.
      #
      # The p2p library is ciInternal.player-p2p-so, built by crane
      # (nix/ci/rust.nix), never by cargokit. Handing it over: the plugin's
      # CMake glue, player/rust_builder/linux/CMakeLists.txt, bundles the file
      # MYDIA_PLAYER_P2P_PREBUILT names and skips apply_cargokit. cargokit's
      # own precompiled-binaries path was not usable: it lives inside the
      # build tool, which run_build_tool.sh starts with a `dart pub get` for
      # packages the player's lockfile does not have (github, toml,
      # ed25519_edwards, ...), so it needs the network before it ever looks
      # for a binary, and it would also need a signed binary host in
      # cargokit.yaml. flutter_rust_bridge loads the library by the fixed name
      # libmydia_player_p2p.so through the runner's $ORIGIN/lib rpath, so the
      # bundle carries the file byte for byte (no fixup).
      playerLinux = (mkPlayerCheck {
        name = "player-linux";
        nativeBuildInputs = [
          noRustInSandbox
          pkgs.clang
          pkgs.cmake
          pkgs.ninja
          pkgs.pkg-config
          pkgs.gtk3
          pkgs.xz
          pkgs.mpv-unwrapped
          pkgs.libsecret
        ];
        script = ''
          export MYDIA_PLAYER_P2P_PREBUILT=${ciRust.playerP2pSo}/lib/libmydia_player_p2p.so
          flutter build linux --release

          bundle=build/linux/x64/release/bundle
          if [ ! -f "$bundle/lib/libmydia_player_p2p.so" ]; then
            echo "$bundle/lib/libmydia_player_p2p.so is missing" >&2
            exit 1
          fi

          # ci-player.yml's "Assert Linux bundle has no symlinks": the
          # workflow uploads the bundle with upload-artifact, which replaces
          # every symlink with a copy of its target. Assigned first, so a
          # failing find fails the check rather than reading as "none".
          first_link=$(find "$bundle" -type l -print -quit)
          if [ -n "$first_link" ]; then
            echo "Linux bundle contains symlinks; upload-artifact flattens them into copies." >&2
            find "$bundle" -type l >&2
            exit 1
          fi
          echo "Linux bundle has no symlinks."

          cp -r "$bundle" $out/bundle
        '';
      }).overrideAttrs { dontFixup = true; };
    in
    {
      _module.args.ciPlayer = { inherit flutter pubCache codegen mkPlayerCheck; };

      ciChecks.player-linux = playerLinux;

      ciInternal = {
        player-pub-cache = pubCache;
        player-codegen = codegen;
      };
    };
}
