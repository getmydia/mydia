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
  perSystem = { pkgs, lib, ci, ciRust, ciTests, ... }:
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
      #
      # Only the FIRST argument is matched: the subcommand must come first
      # (`flutter test ...`, never `flutter --suppress-analytics test ...`),
      # or the shim passes the call through unchanged.
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

      # A writable copy of player-codegen at /build/source, with `extraSource`
      # (a source tree, or null) copied over it, then PUB_CACHE set up and the
      # shell in /build/source/player. HOME must already be writable. Shared
      # by mkPlayerCheck and the player-e2e VM client (nix/tests/player-e2e.nix),
      # which is outside the sandbox but recreates the same absolute paths,
      # since .dart_tool/package_config.json names them.
      #
      # mkPlayerCheck splices this in so its script text, and so every player
      # check's derivation, is byte for byte what it was before the helper
      # existed: keep the lines as they are.
      setupPlayerTree = { extraSource ? null }: ''
        mkdir -p /build/source
        cp -a ${codegen}/. /build/source/
        chmod -R u+w /build/source
        ${lib.optionalString (extraSource != null) "cp -a ${extraSource}/. /build/source/"}
        chmod -R u+w /build/source
        cd /build/source
        ${flutterEnv}
        ${enterPlayer}
      '';

      # mixLib.mkLogCheck's shape, on setupPlayerTree's tree, running `script`
      # in player/ with PUB_CACHE and HOME set, and `flutter` resolving to
      # flutterShim. The output is the log, $out/log.
      #
      # `extraSource`, a source tree (ci.sources.toSource), is copied over
      # the codegen tree for files only that check reads.
      mkPlayerCheck = { name, nativeBuildInputs ? [ ], extraSource ? null, script }:
        (mixLib.mkLogCheck {
          inherit name;
          src = null;
          env = { };
          nativeBuildInputs = [ flutterShim flutter ] ++ nativeBuildInputs;
          script = ''
            ${setupPlayerTree { inherit extraSource; }}${script}
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
      # Flutter's name for the host architecture in build/linux/<arch>/.
      flutterLinuxArch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x64";

      # What a Linux desktop build of the player needs on top of Flutter, with
      # the p2p hand-off variable's value. player-linux and the player-e2e VM
      # client (`flutter test -d linux` builds the app) both use these.
      linuxBuildInputs = [
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
      p2pPrebuilt = "${ciRust.playerP2pSo}/lib/libmydia_player_p2p.so";

      playerLinux = (mkPlayerCheck {
        name = "player-linux";
        nativeBuildInputs = linuxBuildInputs;
        script = ''
          export MYDIA_PLAYER_P2P_PREBUILT=${p2pPrebuilt}
          flutter build linux --release

          bundle=build/linux/${flutterLinuxArch}/release/bundle
          if [ ! -f "$bundle/lib/libmydia_player_p2p.so" ]; then
            echo "$bundle/lib/libmydia_player_p2p.so is missing" >&2
            exit 1
          fi

          # The bundle must hold no symlinks: player-linux.yml builds the
          # release bundle from the same CMake files and uploads it with
          # upload-artifact, which replaces every symlink with a copy of its
          # target. A symlink here is one the release would ship flattened.
          # Assigned first, so a failing find fails the check rather than
          # reading as "none".
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

      # Analyze / Player: zero issues, infos included. The pre-commit hook
      # enforces the same bar, but it only runs inside devenv.
      #
      # `find` stands in for ci-player.yml's `git ls-files`: the sandbox has
      # no .git.
      playerAnalyze = mkPlayerCheck {
        name = "player-analyze";
        script = ''
          dart analyze --fatal-infos lib/l10n

          dart analyze --fatal-infos

          # Check @TestOn files are tagged out of the bundle. A bundle ignores
          # per-file @TestOn, and the compile error it produces for an untagged
          # browser test ("dart:js_interop is not available") does not name the
          # cause. Fail here with the file instead.
          bad=0
          while IFS= read -r f; do
            if grep -E '^@TestOn\(' "$f" | grep -qv "^@TestOn('vm')" \
              && ! grep -qE "^@Tags\(\[.*['\"]skip_very_good_optimization['\"]" "$f"; then
              echo "error: player/$f: @TestOn other than 'vm' needs @Tags(['skip_very_good_optimization']): the very_good bundle cannot compile it" >&2
              bad=1
            fi
          done < <(find test -name '*_test.dart' | sort)
          exit "$bad"
        '';
      };

      playerL10nTest = mkPlayerCheck {
        name = "player-l10n-test";
        script = ''
          flutter test test/l10n
        '';
      };

      # Guards against the web icon set drifting from its SVG sources: a
      # source SVG changed without regenerating, a generated file was
      # hand-edited, or a generated file was deleted. --check needs only
      # coreutils.
      playerIcons = mkPlayerCheck {
        name = "player-icons";
        script = ''
          # Through bash: the script's `#!/usr/bin/env bash` has no /usr/bin/env
          # in the sandbox.
          bash tool/gen-web-icons.sh --check
        '';
      };

      # Test / Player: the VM suite, the television tier and the S3 tests.
      #
      # The S3 server s3_integration_test.dart runs against is ciTests.rustfs,
      # the same RustFS build as the backend test shards and devenv. It listens
      # on 127.0.0.1:9000 with its data under $TMPDIR. CI is set, as on GitHub, so that test
      # fails on a dead server instead of skipping itself.
      #
      # very_good_cli is not used. It is a global tool with some sixty
      # transitive packages that are not in player/pubspec.lock, so running
      # it would mean a second pinned pub cache and a second resolution, to
      # drive one feature: ci-player.yml pinned 1.5.0, and the part of it
      # this suite relies on is the test optimizer, a mason template that
      # writes test/.test_optimizer.dart. The script below reproduces that
      # template (very_good_cli 1.5.0, lib/src/cli/templates, and its
      # pre_gen hook) and the `flutter test` call very_good makes with it.
      # Bumping very_good_cli means re-reading those two files.
      playerTest = mkPlayerCheck {
        name = "player-test";
        nativeBuildInputs = [ ciTests.rustfs pkgs.curl pkgs.perl ];
        # android/, ios/ and macos/ are not in player-codegen; these tests
        # read a manifest, two plists and the Xcode project from them.
        extraSource = ci.sources.toSource ci.sources.playerTestReads;
        script = ''
          export MYDIA_TEST_S3_ENDPOINT=http://127.0.0.1:9000
          export MYDIA_TEST_S3_ACCESS_KEY_ID=mydia
          export MYDIA_TEST_S3_SECRET_ACCESS_KEY=mydia-dev-secret
          export CI=true

          mkdir -p $TMPDIR/rustfs
          rustfs server \
            --address 127.0.0.1:9000 \
            --access-key "$MYDIA_TEST_S3_ACCESS_KEY_ID" \
            --secret-key "$MYDIA_TEST_S3_SECRET_ACCESS_KEY" \
            $TMPDIR/rustfs > $TMPDIR/rustfs.log 2>&1 &
          rustfs_pid=$!
          trap 'kill "$rustfs_pid" 2>/dev/null || true' EXIT
          rustfs_ready=
          for _ in $(seq 1 60); do
            if curl -s --max-time 2 -o /dev/null "$MYDIA_TEST_S3_ENDPOINT"; then
              rustfs_ready=1
              break
            fi
            sleep 1
          done
          if [ -z "$rustfs_ready" ]; then
            echo "RustFS did not answer at $MYDIA_TEST_S3_ENDPOINT" >&2
            cat $TMPDIR/rustfs.log >&2
            exit 1
          fi

          # Run tests. Compiles the suite once instead of once per file, which
          # was 760 of the old step's 988 seconds. test/.test_optimizer.dart
          # imports every *_test.dart, so all files share one isolate: a test
          # that fails only here has leaked global state, and the fix is the
          # leak, not an opt-out. Files tagged skip_very_good_optimization run
          # separately in the same flutter test call.
          #
          # --concurrency=1 is still load-bearing: very_good passes -j 4 by
          # default, and at default concurrency flutter test silently drops
          # 2-4 files while exiting 0.
          optimized=()
          separate=()
          while IFS= read -r f; do
            rel=''${f#test/}
            if perl -0777 -ne 'exit(/@Tags\s*\(\s*\[[\s\S]*?[\x22\x27]skip_very_good_optimization[\x22\x27][\s\S]*?\]\s*\)/ ? 0 : 1)' "$f"; then
              separate+=("$f")
            else
              optimized+=("$rel")
            fi
          done < <(find test -name '*_test.dart' | sort)

          {
            echo "// GENERATED CODE - DO NOT MODIFY BY HAND"
            echo "import 'dart:io';"
            echo "import 'dart:typed_data';"
            echo "import 'package:flutter_test/flutter_test.dart';"
            n=0
            for rel in "''${optimized[@]}"; do
              echo "import '$rel' as _t$n;"
              n=$((n + 1))
            done
            echo "void main() {"
            echo "  goldenFileComparator = _TestOptimizationAwareGoldenFileComparator(goldenFileComparator as LocalFileComparator);"
            n=0
            for rel in "''${optimized[@]}"; do
              echo "  group('$rel', () { _t$n.main(); });"
              n=$((n + 1))
            done
            echo "}"
            cat <<'EOF'
          class _TestOptimizationAwareGoldenFileComparator extends GoldenFileComparator {
            final List<String> goldenFilePaths;
            final LocalFileComparator previousGoldenFileComparator;

            _TestOptimizationAwareGoldenFileComparator(this.previousGoldenFileComparator)
                : goldenFilePaths = _goldenFilePaths;

            static List<String> get _goldenFilePaths =>
                Directory.fromUri((goldenFileComparator as LocalFileComparator).basedir)
                    .listSync(recursive: true, followLinks: true)
                    .whereType<File>()
                    .map((file) => file.path)
                    .where((path) => path.endsWith('.png'))
                    .toList();
            @override
            Future<bool> compare(Uint8List imageBytes, Uri golden) => previousGoldenFileComparator.compare(imageBytes, golden);

            @override
            Uri getTestUri(Uri key, int? version) {
              final keyString = key.toFilePath();
              return Uri.parse(goldenFilePaths
                  .singleWhere((goldenFilePath) => goldenFilePath.endsWith(keyString)));
            }

            @override
            Future<void> update(Uri golden, Uint8List imageBytes) => previousGoldenFileComparator.update(golden, imageBytes);
          }
          EOF
          } > test/.test_optimizer.dart

          echo "Optimized files: ''${#optimized[@]}; run separately: ''${separate[*]}"
          flutter test --concurrency=1 test/.test_optimizer.dart "''${separate[@]}"
          rm -f test/.test_optimizer.dart

          # Run television-tier tests. `directionalPrimary` is compile-time
          # influenced, so the VM run above only ever exercises the
          # non-directional branch. Without this step the whole Android TV
          # code path has no coverage in CI at all.
          #
          # Files are enumerated rather than running the full suite under the
          # define, which would roughly double this job for no extra signal.
          # Empty means the naming convention broke, which must fail rather
          # than silently cover nothing.
          #
          # Read into an array rather than a bare string: an unquoted expansion
          # would word-split a path containing whitespace into several invalid
          # arguments, and `flutter test` would report a missing file instead
          # of the real cause.
          mapfile -t files < <(find test -name '*_tv_test.dart' | sort)
          if [ "''${#files[@]}" -eq 0 ]; then
            echo "No test/**/*_tv_test.dart files matched; expected at least one." >&2
            exit 1
          fi
          echo "Television-tier tests: ''${files[*]}"
          flutter test --concurrency=1 --dart-define=MYDIA_FORCE_TV=true "''${files[@]}"
        '';
      };

      # Run browser tests. The VM run in player-test skips every
      # @TestOn('browser') file. Without this check the IndexedDB keystore has
      # no coverage in CI at all.
      #
      # The files are enumerated rather than passing a bare `--platform
      # chrome`, because that would try to run the whole suite in a browser
      # and most of it needs dart:io. Empty means the naming convention broke,
      # which must fail rather than silently cover nothing.
      #
      # No --concurrency here, unlike the VM run: flutter parses it and then
      # ignores it for web runs, printing a warning that reads like a mistake.
      #
      playerTestWeb = mkPlayerCheck {
        name = "player-test-web";
        nativeBuildInputs = [ pkgs.chromium ];
        script = ''
          export CHROME_EXECUTABLE=${pkgs.chromium}/bin/chromium
          mapfile -t files < <(find test -name '*_web_test.dart' | sort)
          if [ "''${#files[@]}" -eq 0 ]; then
            echo "No test/**/*_web_test.dart files matched; expected at least one." >&2
            exit 1
          fi
          echo "Browser tests: ''${files[*]}"
          flutter test --platform chrome "''${files[@]}"
        '';
      };

      # Build / Web: nothing compiled the player for the web until this
      # existed. The platform builds cover Windows, macOS, Linux and Android,
      # and `icons` only diffs the generated SVG set, so 183 commits landed on
      # player/ between the public web player merging and its first deploy
      # without one of them being checked against the web target. That gap is
      # only visible at deploy time, where it would now break a release:
      # deploy-web-player.yml runs from release.yml.
      #
      # This builds the same bundle the deploy builds, with the same flags,
      # minus the wasm module. The Rust half needs wasm-pack and a
      # flutter_rust_bridge codegen install (player/tool/build_web.sh), which
      # is too much for every player PR. The split is deliberate rather than
      # lazy: the rust-p2p-core-wasm check already compiles
      # native/mydia_p2p_core for wasm32-unknown-unknown, so the crate
      # reaching wasm is covered, and what stays uncovered here is wasm-pack's
      # packaging step, whose inputs are pinned toolchain versions that move
      # only on a deliberate bump. Dart source, which every PR touches, is
      # what this catches.
      #
      # MYDIA_WEB_P2P=true matters even without the module present: it
      # selects the public-web branch in main.dart, so this compiles the code
      # path the deploy actually ships rather than the instance-hosted one.
      #
      # The bundle is $out/web, next to the log.
      playerWeb = (mkPlayerCheck {
        name = "player-web";
        script = ''
          flutter build web --release --base-href / \
            --no-web-resources-cdn \
            --pwa-strategy=none \
            --dart-define=MYDIA_WEB_P2P=true

          # build_web.sh asserts this file reached build/web; this also
          # asserts it still says what it has to say. Both directives are
          # load-bearing: without them the deployed page is not cross-origin
          # isolated, there is no SharedArrayBuffer, and RustLib.init() throws
          # in every browser. Checking only for the file's presence would wave
          # through a _headers whose directives had been edited away, which
          # breaks identically and is the likelier edit of the two.
          headers=build/web/_headers
          if [ ! -f "$headers" ]; then
            echo "error: _headers did not make it into build/web." >&2
            exit 1
          fi
          for directive in \
            "Cross-Origin-Opener-Policy: same-origin" \
            "Cross-Origin-Embedder-Policy: require-corp"; do
            if ! grep -qF "$directive" "$headers"; then
              echo "error: $headers no longer sets '$directive'. The deployed page" >&2
              echo "       would not be cross-origin isolated, so the p2p wasm module" >&2
              echo "       could not instantiate in any browser." >&2
              exit 1
            fi
          done

          cp -r build/web $out/web
        '';
      }).overrideAttrs { dontFixup = true; };
    in
    {
      _module.args.ciPlayer = {
        inherit flutter pubCache codegen mkPlayerCheck;
        # For the player-e2e VM client, outside mkPlayerCheck.
        inherit flutterShim setupPlayerTree linuxBuildInputs p2pPrebuilt;
      };

      ciChecks.player-linux = playerLinux;
      ciChecks.player-analyze = playerAnalyze;
      ciChecks.player-l10n-test = playerL10nTest;
      ciChecks.player-icons = playerIcons;
      ciChecks.player-test = playerTest;
      ciChecks.player-test-web = playerTestWeb;
      ciChecks.player-web = playerWeb;

      ciInternal = {
        player-pub-cache = pubCache;
        player-codegen = codegen;
      };
    };
}
