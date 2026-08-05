#!/usr/bin/env bash
# Runs inside the flatpak-builder sandbox as the mydia-player module's only
# build command, with the repository root as the working directory.
#
# Reads the Flutter version from player/.fvmrc and lets rustup resolve
# rust-toolchain.toml. Neither version is named here; see the Flutter and Rust
# pin guards in ci-nix.yml and ci.yml, which scan this directory.
set -euo pipefail

BUILD_HOME="${PWD}/.flatpak-build-home"
mkdir -p "$BUILD_HOME"
export HOME="$BUILD_HOME"
export PUB_CACHE="$BUILD_HOME/.pub-cache"

# --- Flutter -----------------------------------------------------------------
FLUTTER_VERSION="$(python3 -c 'import json;print(json.load(open("player/.fvmrc"))["flutter"])')"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

echo "Fetching Flutter ${FLUTTER_VERSION}"
curl -fsSL "$FLUTTER_URL" -o "$BUILD_HOME/flutter.tar.xz"
tar -xf "$BUILD_HOME/flutter.tar.xz" -C "$BUILD_HOME"
export PATH="$BUILD_HOME/flutter/bin:$PATH"

# The tarball ships a git repo whose ownership will not match the build user;
# without this every flutter invocation aborts on "dubious ownership".
git config --global --add safe.directory "$BUILD_HOME/flutter"

flutter config --no-analytics --no-cli-animations
flutter --version

# --- Rust --------------------------------------------------------------------
# rustup reads rust-toolchain.toml at the repository root on first use, so the
# pinned channel installs itself with no version named here.
echo "Installing Rust from rust-toolchain.toml"
curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain none
export PATH="$BUILD_HOME/.cargo/bin:$PATH"
rustup show

# --- Build -------------------------------------------------------------------
cd player
flutter pub get
flutter pub run build_runner build --delete-conflicting-outputs
flutter build linux --release
cd ..

# --- Install -----------------------------------------------------------------
BUNDLE="player/build/linux/x64/release/bundle"
install -d /app/lib/mydia-player
cp -r "$BUNDLE"/. /app/lib/mydia-player/
chmod +x /app/lib/mydia-player/mydia-player

# $ORIGIN in the runner's RPATH resolves through the symlink to the real
# directory, so the bundled libflutter_linux_gtk.so is still found.
install -d /app/bin
ln -sf ../lib/mydia-player/mydia-player /app/bin/mydia-player

install -Dm644 player/flatpak/dev.mydia.player.desktop \
  /app/share/applications/dev.mydia.player.desktop
install -Dm644 player/flatpak/dev.mydia.player.metainfo.xml \
  /app/share/metainfo/dev.mydia.player.metainfo.xml

# Icons come from the existing player assets rather than a second copy checked
# into player/flatpak/, which would only drift.
install -Dm644 player/assets/icon.svg \
  /app/share/icons/hicolor/scalable/apps/dev.mydia.player.svg
for size in 64 128 256; do
  install -d "/app/share/icons/hicolor/${size}x${size}/apps"
  rsvg-convert -w "$size" -h "$size" player/assets/icon.svg \
    -o "/app/share/icons/hicolor/${size}x${size}/apps/dev.mydia.player.png"
done

echo "Installed mydia-player into /app"
