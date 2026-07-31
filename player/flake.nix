{
  description = "Mydia Player - Flutter media player client";

  inputs = {
    # Same revs as devenv.lock, so the Android shell and the dev shell agree on
    # Flutter, the Android toolchain and Rust. Bump alongside devenv, not alone.
    #
    # The rust-overlay rev is load-bearing, not cosmetic: the previously pinned
    # overlay has no rust-bin.stable."1.96.0", so the toolchain below cannot
    # evaluate without it.
    nixpkgs.url = "github:NixOS/nixpkgs/567a49d1913ce81ac6e9582e3553dd90a955875f";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay/d0e019d9543f0f1215a3d961fc4dca59aa29c638";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };

        # Flutter comes from player/.fvmrc via the shared resolver, the same one
        # devenv.nix uses. Never name a Flutter version here.
        flutterPkg = import ./flutter-version.nix { inherit pkgs; };

        # Android SDK configuration with NDK
        androidComposition = pkgs.androidenv.composeAndroidPackages {
          cmdLineToolsVersion = "13.0";
          platformToolsVersion = "35.0.2";
          buildToolsVersions = [ "30.0.3" "33.0.1" "34.0.0" "35.0.0" "36.0.0" ];
          platformVersions = [ "30" "33" "34" "35" "36" ];
          abiVersions = [ "arm64-v8a" "armeabi-v7a" "x86_64" ];
          includeNDK = true;
          ndkVersions = [ "27.0.12077973" "28.2.13676358" ];
          cmakeVersions = [ "3.22.1" ];
          includeEmulator = false;
        };

        androidSdk = androidComposition.androidsdk;
        ndkPath = "${androidSdk}/libexec/android-sdk/ndk/28.2.13676358";

        # Rust pinned to 1.96.0 to match devenv.nix (languages.rust.version), so
        # this shell and the dev shell agree on the compiler a developer gets when
        # running cargo by hand.
        #
        # Know the limit of this pin: it does NOT govern the .so files in the APK.
        # cargokit builds the native library with `rustup run stable cargo build`
        # (rust_builder/cargokit/build_tool/lib/src/builder.dart), resolving rustup
        # from PATH, so the APK's Rust is the host rustup's default stable. Bumping
        # or bisecting the version below will not change the shipped artifact. The
        # targets here still matter: they are what the interactive shell offers.
        rustToolchain = pkgs.rust-bin.stable."1.96.0".default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
          targets = [
            "aarch64-linux-android"
            "armv7-linux-androideabi"
            "x86_64-linux-android"
            "i686-linux-android"
          ];
        };

        # Linux build dependencies for Flutter plugins
        linuxBuildDeps = with pkgs; [
          # Build tools
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

      in {
        devShells.default = pkgs.mkShell {
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
          CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang";
          CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang";
          CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android21-clang";
          CARGO_TARGET_I686_LINUX_ANDROID_LINKER = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/i686-linux-android21-clang";

          # CC for Android targets
          CC_aarch64_linux_android = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang";
          CC_armv7_linux_androideabi = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang";
          CC_x86_64_linux_android = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android21-clang";
          CC_i686_linux_android = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/i686-linux-android21-clang";

          # AR for Android targets
          AR_aarch64_linux_android = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar";
          AR_armv7_linux_androideabi = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar";
          AR_x86_64_linux_android = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar";
          AR_i686_linux_android = "${ndkPath}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar";

          shellHook = ''
            # $HOME/.cargo/bin goes LAST, after the store paths. It holds
            # cargo-installed helpers (flutter_rust_bridge_codegen) and the
            # `rustup` cargokit shells out to, both of which must stay findable
            # — but its `rustc` and `cargo` are rustup shims resolving to
            # whatever toolchain the host defaults to. Ahead of $PATH they
            # shadow rustToolchain and silently undo the pin above.
            export PATH="${androidSdk}/libexec/android-sdk/platform-tools:$PATH:$HOME/.cargo/bin"
            # Note: Do NOT add NDK toolchain to PATH - it interferes with Linux builds.
            # Rust cross-compilation uses the CARGO_TARGET_* env vars instead.

            # Delete stale local.properties that may have wrong SDK paths
            rm -f android/local.properties 2>/dev/null || true

            # Ensure flutter_rust_bridge_codegen is installed
            if ! command -v flutter_rust_bridge_codegen &> /dev/null; then
              echo "Installing flutter_rust_bridge_codegen..."
              cargo install flutter_rust_bridge_codegen --quiet
            fi

            echo ""
            echo "Flutter + Rust Android development shell"
            echo ""
            echo "Rust targets installed:"
            rustup target list --installed 2>/dev/null || rustc --print target-list | grep android | head -4
            echo ""
            echo "Commands:"
            echo "  flutter run                           - Build and run on device"
            echo "  flutter build apk                     - Build release APK"
            echo "  flutter_rust_bridge_codegen generate  - Regenerate Rust-Dart bridge"
            echo ""
          '';
        };

        # Exposed so CI can assert the pinned Flutter resolves without building
        # an SDK or any Android tooling: `nix eval ./player#packages.<sys>.flutter.version`.
        packages.flutter = flutterPkg;
      }
    );
}
