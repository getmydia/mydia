{ inputs, ... }:

# The Flutter player's Android build shell.
#
# This lives in the root flake, not in player/, for one reason: a flake cannot
# read above its own root, so a flake rooted at player/ could not read the
# repo's rust-toolchain.toml and had to hand-copy the Rust version. See #252.
#
# The daily Elixir/Phoenix loop still lives in devenv.nix; this is the one
# exception, because Nix is the only practical way to get the Android SDK, NDK
# and cross-compilation toolchain.
#
# It uses its own pinned nixpkgs (inputs.nixpkgs-android) rather than the root
# nixpkgs. That is deliberate: it keeps the Android SDK, NDK and Flutter package
# set byte-identical to what player/flake.nix resolved before this move, so
# adopting it does not re-evaluate the production package, the NixOS module or
# nix/checks, and does not silently change the shipped Android toolchain.

{
  perSystem = { system, ... }:
    let
      pkgs = import inputs.nixpkgs-android {
        inherit system;
        overlays = [ inputs.rust-overlay.overlays.default ];
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };

      # Flutter comes from player/.fvmrc via the shared resolver, the same one
      # devenv.nix uses. Never name a Flutter version here.
      flutterPkg = import ../../player/flutter-version.nix { inherit pkgs; };

      # Rust comes from rust-toolchain.toml, the same file cargokit, devenv and
      # both Dockerfiles read. Never name a Rust version here.
      rustChannel =
        (builtins.fromTOML
          (builtins.readFile ../../rust-toolchain.toml)).toolchain.channel;

      # The Android targets are this shell's job, not the toolchain file's:
      # listing them there would make every plain `cargo` call in the repo
      # download four extra standard libraries. cargokit builds against
      # whichever cargo is first on PATH, which inside this shell is this one.
      rustToolchain = pkgs.rust-bin.stable.${rustChannel}.default.override {
        extensions = [ "rust-src" "rust-analyzer" ];
        targets = [
          "aarch64-linux-android"
          "armv7-linux-androideabi"
          "x86_64-linux-android"
          "i686-linux-android"
        ];
      };

      androidComposition = pkgs.androidenv.composeAndroidPackages {
        cmdLineToolsVersion = "13.0";
        platformToolsVersion = "35.0.2";
        buildToolsVersions = [ "30.0.3" "33.0.1" "34.0.0" "35.0.0" "36.0.0" ];
        # 37.0 is load-bearing, not padding. The pinned flutter_secure_storage
        # 11 declares compileSdk = 37 (10.3.1 declared 36), and AGP reacts by
        # trying to install the missing platform, which cannot work against
        # this read-only store SDK: the release build dies with "The SDK
        # directory is not writable" before assembling anything.
        platformVersions = [ "30" "33" "34" "35" "36" "37.0" ];
        abiVersions = [ "arm64-v8a" "armeabi-v7a" "x86_64" ];
        includeNDK = true;
        ndkVersions = [ "27.0.12077973" "28.2.13676358" ];
        cmakeVersions = [ "3.22.1" ];
        includeEmulator = false;
      };

      androidSdk = androidComposition.androidsdk;
      ndkPath = "${androidSdk}/libexec/android-sdk/ndk/28.2.13676358";
      ndkBin =
        "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin";

      # The Android TV emulator runtime, composed on its own rather than added
      # to androidComposition above. composeAndroidPackages takes the cross
      # product of platformVersions, systemImageTypes and abiVersions, so
      # includeSystemImages there would download a TV image for each of the
      # five build platforms and three build ABIs. Nothing here builds an APK:
      # the build SDK above stays the only one Gradle and the NDK linkers see.
      androidTvComposition = pkgs.androidenv.composeAndroidPackages {
        cmdLineToolsVersion = "13.0";
        platformToolsVersion = "35.0.2";
        buildToolsVersions = [ ];
        platformVersions = [ "36" ];
        abiVersions = [ "x86_64" ];
        includeSystemImages = true;
        systemImageTypes = [ "android-tv" ];
        includeEmulator = true;
        includeCmake = false;
      };

      androidTvSdk = androidTvComposition.androidsdk;
      androidTvSdkRoot = "${androidTvSdk}/libexec/android-sdk";

      # Linux build dependencies for Flutter plugins
      linuxBuildDeps = with pkgs; [
        cmake
        ninja
        pkg-config
        clang

        # GTK3 for Flutter Linux
        gtk3
        gtk3.dev

        # flutter_secure_storage
        libsecret

        # volume_controller (ALSA)
        alsa-lib
        alsa-lib.dev

        # media_kit (video playback)
        mpv
        libass

        # General Linux deps
        pcre2
        util-linux
        libselinux
        libsepol
        libthai
        libdatrie
        xorg.libXdmcp
        libxkbcommon
        libepoxy
      ];

      # The one Android build environment, shared by both shells. Everything a
      # shell needs to compile the player lives here, so the TV shell cannot
      # drift from the build shell: the env vars, the four Android targets'
      # linker/CC/AR settings and the codegen hook are defined once.
      androidShellAttrs = {
        buildInputs = [
          flutterPkg
          androidSdk
          pkgs.jdk17
          rustToolchain
        ] ++ linuxBuildDeps;

        ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
        ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
        ANDROID_NDK_HOME = ndkPath;
        NDK_HOME = ndkPath;
        JAVA_HOME = "${pkgs.jdk17}";

        # Cargo configuration for Android cross-compilation
        CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER =
          "${ndkBin}/aarch64-linux-android21-clang";
        CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER =
          "${ndkBin}/armv7a-linux-androideabi21-clang";
        CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER =
          "${ndkBin}/x86_64-linux-android21-clang";
        CARGO_TARGET_I686_LINUX_ANDROID_LINKER =
          "${ndkBin}/i686-linux-android21-clang";

        # CC for Android targets
        CC_aarch64_linux_android = "${ndkBin}/aarch64-linux-android21-clang";
        CC_armv7_linux_androideabi = "${ndkBin}/armv7a-linux-androideabi21-clang";
        CC_x86_64_linux_android = "${ndkBin}/x86_64-linux-android21-clang";
        CC_i686_linux_android = "${ndkBin}/i686-linux-android21-clang";

        # AR for Android targets
        AR_aarch64_linux_android = "${ndkBin}/llvm-ar";
        AR_armv7_linux_androideabi = "${ndkBin}/llvm-ar";
        AR_x86_64_linux_android = "${ndkBin}/llvm-ar";
        AR_i686_linux_android = "${ndkBin}/llvm-ar";

        shellHook = ''
          # $HOME/.cargo/bin goes LAST, after the store paths. It holds
          # cargo-installed helpers (flutter_rust_bridge_codegen) and the
          # `rustup` cargokit falls back to, both of which must stay findable
          # — but its `rustc` and `cargo` are rustup shims resolving to
          # whatever toolchain the host defaults to. Ahead of $PATH they would
          # shadow rustToolchain and silently undo the pin above.
          export PATH="${androidSdk}/libexec/android-sdk/platform-tools:$PATH:$HOME/.cargo/bin"
          # Note: Do NOT add NDK toolchain to PATH - it interferes with Linux
          # builds. Rust cross-compilation uses the CARGO_TARGET_* env vars.

          # Delete stale local.properties that may have wrong SDK paths
          rm -f player/android/local.properties 2>/dev/null || true

          # flutter_rust_bridge_codegen must match the flutter_rust_bridge
          # version pinned in player/rust/mydia_player_p2p/Cargo.toml. A
          # mismatch regenerates every binding at the wrong version without
          # failing, so the version is read from the crate, never restated
          # here, and a wrong existing install is corrected rather than kept.
          #
          # CARGO_INSTALL_ROOT/bin goes ahead of $HOME/.cargo/bin, which the
          # line above appends: a stale global copy there would otherwise
          # shadow the pinned one and silently regenerate at its own version.
          if [ -n "''${CARGO_INSTALL_ROOT:-}" ]; then
            export PATH="$CARGO_INSTALL_ROOT/bin:$PATH"
          fi
          frbVersion="$(sed -n 's/^flutter_rust_bridge = "=\(.*\)"$/\1/p' \
            player/rust/mydia_player_p2p/Cargo.toml)"
          if [ -z "$frbVersion" ]; then
            echo "ERROR: could not read the flutter_rust_bridge pin from player/rust/mydia_player_p2p/Cargo.toml" >&2
          elif ! flutter_rust_bridge_codegen --version 2>/dev/null | grep -qF "$frbVersion"; then
            echo "Installing flutter_rust_bridge_codegen $frbVersion..."
            cargo install flutter_rust_bridge_codegen --version "$frbVersion" --locked --force --quiet
          fi

          echo ""
          echo "Flutter + Rust Android development shell"
          echo ""
          echo "Rust: $(rustc --version) (from rust-toolchain.toml)"
          echo "Targets:"
          rustc --print target-list | grep android | head -4
          echo ""
          echo "Commands:"
          echo "  flutter run                           - Build and run on device"
          echo "  flutter build apk                     - Build release APK"
          echo "  flutter_rust_bridge_codegen generate  - Regenerate Rust-Dart bridge"
          echo ""
        '';
      };
    in
    {
      devShells.android = pkgs.mkShell androidShellAttrs;

      # Same shell plus the emulator runtime. The extra SDK is an input, never
      # a PATH-priority change: the emulator, avdmanager and the API 36
      # android-tv x86_64 image are read from MYDIA_ANDROID_TV_SDK_ROOT, so
      # nothing here can displace the build SDK's own tools.
      devShells.android-tv = pkgs.mkShell (androidShellAttrs // {
        buildInputs = androidShellAttrs.buildInputs ++ [ androidTvSdk ];
        MYDIA_ANDROID_TV_SDK_ROOT = androidTvSdkRoot;
        shellHook = androidShellAttrs.shellHook + ''
          echo "  mydia Android TV image               - API 36 x86_64"
        '';
      });

      # Exposed so CI can assert the pinned Flutter resolves without building an
      # SDK or any Android tooling:
      #   nix eval --raw .#packages.<system>.flutter.version
      packages.flutter = flutterPkg;
    };
}
