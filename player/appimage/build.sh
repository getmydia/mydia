#!/usr/bin/env bash
# Builds the player AppImage. Runs as root inside ubuntu:22.04 with the
# repository root as the working directory:
#
#   docker run --rm -v "$PWD:/src" -w /src \
#     -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
#     ubuntu:22.04 player/appimage/build.sh
#
# 22.04 sets the glibc floor (2.35). Flutter comes from player/.fvmrc and Rust
# from rust-toolchain.toml, as in player/flatpak/build.sh; neither version is
# named here (see the pin guards in ci-nix.yml and ci.yml).
set -euo pipefail

ROOT="$PWD"
OUT="$ROOT/player/build/appimage"
BUILD_HOME="$OUT/home"
MPV_PREFIX="${MPV_PREFIX:-/opt/mpv-prefix}"
SRC_DIR="$OUT/src"
mkdir -p "$BUILD_HOME" "$SRC_DIR"

# Hands build output back to the invoking user on a local run, where the
# container's root would otherwise own player/build.
restore_build_outputs() {
  chown -R "${HOST_UID:-0}:${HOST_GID:-${HOST_UID:-0}}" "$ROOT/player/build" \
    "$ROOT/player/.build-channel" 2>/dev/null || true
  if [ -f "$ROOT/.git.appimage-bak" ]; then
    mv -f "$ROOT/.git.appimage-bak" "$ROOT/.git"
  fi
  if [ -f "$ROOT/player/linux/runner/CMakeLists.txt.appimage-bak" ]; then
    mv -f "$ROOT/player/linux/runner/CMakeLists.txt.appimage-bak" \
      "$ROOT/player/linux/runner/CMakeLists.txt"
  fi
}
if [ -n "${HOST_UID:-}" ]; then
  trap restore_build_outputs EXIT
fi

# --- System packages ---------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git xz-utils unzip file patchelf pkg-config \
  build-essential clang cmake ninja-build nasm python3 python3-pip \
  autoconf automake libtool \
  libstdc++-12-dev \
  libgtk-3-dev liblzma-dev libsecret-1-dev libepoxy-dev \
  libxml2-dev \
  libfreetype-dev libfribidi-dev libharfbuzz-dev libfontconfig-dev \
  libgnutls28-dev libva-dev libdrm-dev \
  libegl-dev libgl-dev libx11-dev libxext-dev libxpresent-dev libxrandr-dev \
  libxss-dev libxv-dev libwayland-dev wayland-protocols libxkbcommon-dev \
  libpulse-dev libasound2-dev \
  librsvg2-bin desktop-file-utils xvfb xauth \
  libegl1-mesa libgl1-mesa-dri libgles2
# wayland-scanner needs libxml-2.0 at build time (libxml2-dev).
# libass autogen.sh calls autoreconf, which lives in the autoconf package.
# mpv 0.41 needs meson 1.3; 22.04 ships 0.61. libplacebo's generator needs jinja2.
pip3 install --no-cache-dir 'meson>=1.3' jinja2
export PATH="/usr/local/bin:$PATH"

# --- mpv stack ---------------------------------------------------------------
eval "$("$ROOT/player/appimage/pins.sh")"
export PKG_CONFIG_PATH="$MPV_PREFIX/lib/pkgconfig:$MPV_PREFIX/share/pkgconfig"
export LD_LIBRARY_PATH="$MPV_PREFIX/lib"

fetch() { # url tag dir
  [ -d "$SRC_DIR/$3" ] || git clone --depth 1 --recurse-submodules --branch "$2" "$1" "$SRC_DIR/$3"
}

if [ -e "$MPV_PREFIX/lib/libmpv.so.2" ]; then
  echo "Reusing $MPV_PREFIX (cached)"
else
  fetch https://github.com/FFmpeg/FFmpeg.git "$FFMPEG_TAG" ffmpeg
  (cd "$SRC_DIR/ffmpeg" && ./configure --prefix="$MPV_PREFIX" \
      --enable-shared --disable-static --disable-programs --disable-doc \
      --enable-gnutls --enable-vaapi \
    && make -j"$(nproc)" && make install)

  fetch https://github.com/libass/libass.git "$LIBASS_TAG" libass
  (cd "$SRC_DIR/libass" && ./autogen.sh && ./configure --prefix="$MPV_PREFIX" --disable-static \
    && make -j"$(nproc)" && make install)

  fetch https://code.videolan.org/videolan/libplacebo.git "$LIBPLACEBO_TAG" libplacebo
  # No Vulkan: media_kit_video renders through mpv's OpenGL render API.
  meson setup "$SRC_DIR/libplacebo/build" "$SRC_DIR/libplacebo" --prefix="$MPV_PREFIX" \
    --libdir=lib --buildtype=release -Dvulkan=disabled -Dopengl=enabled -Ddemos=false
  meson install -C "$SRC_DIR/libplacebo/build"

  # mpv 0.41 needs wayland-client >= 1.21; 22.04 ships 1.20.
  fetch https://gitlab.freedesktop.org/wayland/wayland.git 1.22.0 wayland
  rm -rf "$SRC_DIR/wayland/build"
  meson setup "$SRC_DIR/wayland/build" "$SRC_DIR/wayland" --prefix="$MPV_PREFIX" \
    --libdir=lib --buildtype=release -Ddocumentation=false -Dtests=false
  meson install -C "$SRC_DIR/wayland/build"

  # mpv 0.41 needs >= 1.31 to configure; its sources call color-management-v1
  # helpers, which meson only generates from protocols >= 1.41. 22.04 ships 1.25.
  rm -rf "$SRC_DIR/wayland-protocols"
  fetch https://gitlab.freedesktop.org/wayland/wayland-protocols.git 1.41 wayland-protocols
  rm -rf "$SRC_DIR/wayland-protocols/build"
  meson setup "$SRC_DIR/wayland-protocols/build" "$SRC_DIR/wayland-protocols" \
    --prefix="$MPV_PREFIX" --libdir=lib -Dtests=false
  meson install -C "$SRC_DIR/wayland-protocols/build"

  fetch https://github.com/mpv-player/mpv.git "$MPV_TAG" mpv
  # Explicit enables so a missing -dev package fails here, not as a libmpv
  # that plays audio over a black frame.
  rm -rf "$SRC_DIR/mpv/build"
  meson setup "$SRC_DIR/mpv/build" "$SRC_DIR/mpv" --prefix="$MPV_PREFIX" \
    --libdir=lib --buildtype=release -Dlibmpv=true -Dcplayer=false \
    -Dmanpage-build=disabled -Dlua=disabled -Dwerror=false \
    -Dgl=enabled -Degl=enabled -Dx11=enabled -Dwayland=enabled -Dvaapi=enabled
  meson install -C "$SRC_DIR/mpv/build"
fi

# --- Flutter and Rust --------------------------------------------------------
# Docker bind-mounts only /src; a worktree .git file points at a gitdir the
# container cannot see. Point it at a throwaway bare repo for this run, restored
# on EXIT (see restore_build_outputs).
if [ -f "$ROOT/.git" ] && grep -q '^gitdir: ' "$ROOT/.git"; then
  worktree_gitdir=$(sed -n 's/^gitdir: //p' "$ROOT/.git" | tr -d '[:space:]')
  if [ -n "$worktree_gitdir" ] && [ ! -e "$worktree_gitdir/HEAD" ]; then
    bare="$OUT/worktree-gitdir"
    rm -rf "$bare"
    git init -q --bare "$bare"
    cp -a "$ROOT/.git" "$ROOT/.git.appimage-bak"
    # Relative to the worktree root so the pointer stays valid on the host bind mount.
    printf 'gitdir: %s\n' "player/build/appimage/worktree-gitdir" > "$ROOT/.git"
    trap restore_build_outputs EXIT
  fi
fi
export HOME="$BUILD_HOME" PUB_CACHE="$BUILD_HOME/.pub-cache"
FLUTTER_VERSION="$(python3 -c 'import json;print(json.load(open("player/.fvmrc"))["flutter"])')"
if [ ! -x "$BUILD_HOME/flutter/bin/flutter" ]; then
  curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    | tar -xJ -C "$BUILD_HOME"
fi
git config --global --add safe.directory '*'
# The Flutter tarball is a git checkout; in docker its owner is root.
git config --global --add safe.directory "$BUILD_HOME/flutter"
export PATH="$BUILD_HOME/flutter/bin:$BUILD_HOME/.cargo/bin:$PATH"
flutter config --no-analytics --no-cli-animations
[ -x "$BUILD_HOME/.cargo/bin/rustup" ] || \
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain none
rustup show

# --- Flutter build -----------------------------------------------------------
# 22.04 ships glib 2.72; the Linux runner uses G_CONNECT_DEFAULT (2.74+).
cat > "$OUT/glib-compat.h" << 'EOF'
#pragma once
#include <glib-object.h>
#ifndef G_CONNECT_DEFAULT
#define G_CONNECT_DEFAULT ((GConnectFlags)0)
#endif
EOF
# Flutter's linux cmake ignores CXX/CMAKE_CXX_COMPILER; patch the runner target.
RUNNER_CMAKE="$ROOT/player/linux/runner/CMakeLists.txt"
GLIB_HDR="$OUT/glib-compat.h"
[ -f "$RUNNER_CMAKE.appimage-bak" ] || cp -a "$RUNNER_CMAKE" "$RUNNER_CMAKE.appimage-bak"
cp -a "$RUNNER_CMAKE.appimage-bak" "$RUNNER_CMAKE"
sed -i "/^apply_standard_settings(\${BINARY_NAME})$/a\\
# APPIMAGE_GLIB_COMPAT: 22.04 glib lacks G_CONNECT_DEFAULT (see player/appimage/build.sh).\\
target_compile_options(\${BINARY_NAME} PRIVATE \"-include${GLIB_HDR}\")" "$RUNNER_CMAKE"

cd "$ROOT/player"
flutter pub get --enforce-lockfile
flutter pub run build_runner build --delete-conflicting-outputs
[ -n "${MYDIA_VERSION:-}" ] && ./tool/apply-channel.sh "$MYDIA_VERSION"
CHANNEL=stable
[ -f .build-channel ] && CHANNEL="$(cat .build-channel)"
flutter build linux --release --dart-define=MYDIA_CHANNEL="$CHANNEL"
cd "$ROOT"

# --- AppDir ------------------------------------------------------------------
APPDIR="$OUT/AppDir"
rm -rf "$APPDIR"
install -d "$APPDIR/usr/lib/mydia-player"
# The runner finds data/ and lib/ relative to itself, so the bundle stays whole.
cp -r player/build/linux/x64/release/bundle/. "$APPDIR/usr/lib/mydia-player/"
install -m755 player/appimage/AppRun "$APPDIR/AppRun"
install -Dm644 player/flatpak/dev.mydia.player.desktop "$APPDIR/dev.mydia.player.desktop"
ICON_SRC=player/assets/icon.svg
[ "$CHANNEL" != stable ] && ICON_SRC="player/assets/icon-$CHANNEL.svg"
rsvg-convert -w 256 -h 256 "$ICON_SRC" -o "$APPDIR/dev.mydia.player.png"
install -Dm644 "$APPDIR/dev.mydia.player.png" \
  "$APPDIR/usr/share/icons/hicolor/256x256/apps/dev.mydia.player.png"
ln -sf dev.mydia.player.png "$APPDIR/.DirIcon"

# --- Tools -------------------------------------------------------------------
TOOLS="$OUT/tools"
mkdir -p "$TOOLS"
get_tool() { [ -x "$TOOLS/$1" ] || { curl -fsSL "$2" -o "$TOOLS/$1" && chmod +x "$TOOLS/$1"; }; }
get_tool linuxdeploy https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage
get_tool linuxdeploy-plugin-gtk.sh https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/7a3fbc31a9e5075073ff8790f26effbac5f84453/linuxdeploy-plugin-gtk.sh
get_tool appimagetool https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
export PATH="$TOOLS:$PATH"
# Containers have no FUSE.
export APPIMAGE_EXTRACT_AND_RUN=1

# --- Bundle dependencies and pack --------------------------------------------
# The runner and its plugins stay where they are; only their dependencies are
# copied into usr/lib. The GTK plugin adds GTK's loaders, schemas and an
# AppRun hook.
DEPLOY_GTK_VERSION=3 linuxdeploy --appdir "$APPDIR" \
  --deploy-deps-only "$APPDIR/usr/lib/mydia-player" \
  --plugin gtk
# linuxdeploy blacklists some GTK deps; vendor any ELF dependency outside AppDir (smoke-test).
# Resolve like AppRun so we do not rely on the build image's system libs.
export LD_LIBRARY_PATH="$APPDIR/usr/lib/mydia-player/lib:$APPDIR/usr/lib"
glibc_re='^(ld-linux|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libgcc_s\.so|libstdc\+\+\.so|libresolv\.so|libnss_|libutil\.so)'
for _ in $(seq 1 40); do
  copied=0
  while IFS= read -r -d '' elf; do
    file -b "$elf" | grep -q ELF || continue
    while IFS= read -r line; do
      case "$line" in
        NOTFOUND:*)
          name="${line#NOTFOUND:}"
          name="${name%;}"
          path=$(ldconfig -p 2>/dev/null | awk -v n="$name" '$1==n {print $NF; exit}')
          ;;
        /*)
          path="$line"
          ;;
        *)
          continue
          ;;
      esac
      [ -z "${path:-}" ] || [ ! -f "$path" ] && continue
      case "$path" in "$APPDIR"/*) continue ;; esac
      base=$(basename "$path")
      echo "$base" | grep -qE "$glibc_re" && continue
      # linuxdeploy blacklists GL/EGL driver entry points; still vendor libGLdispatch etc.
      echo "$base" | grep -qE '^lib(EGL\.so|GL\.so|GLX\.so|GLES)' && continue
      if [ ! -e "$APPDIR/usr/lib/$base" ]; then
        install -m644 "$path" "$APPDIR/usr/lib/$base"
        copied=1
      fi
    done < <(
      ldd "$elf" 2>/dev/null | awk '
        /=> \// { print $3 }
        /=> not found/ { print "NOTFOUND:" $1 }
      '
    )
  done < <(find "$APPDIR/usr/lib" "$APPDIR/usr/lib/mydia-player" -type f \( -name '*.so*' -o -name mydia-player \) -print0)
  [ "$copied" = 0 ] && break
done
# Flutter needs Mesa GL/EGL on minimal hosts; linuxdeploy leaves GL/EGL to the distro.
for lib in libEGL.so.1 libEGL_mesa.so.0 libGL.so.1 libGLX.so.0 libGLESv2.so.2 libglapi.so.0 libgbm.so.1 libGLdispatch.so.0 libdrm.so.2; do
  install -m644 "/lib/x86_64-linux-gnu/$lib" "$APPDIR/usr/lib/"
done
install -d "$APPDIR/usr/share/glvnd/egl_vendor.d" "$APPDIR/usr/lib/dri"
install -Dm644 /usr/share/glvnd/egl_vendor.d/50_mesa.json "$APPDIR/usr/share/glvnd/egl_vendor.d/50_mesa.json"
install -m644 /usr/lib/x86_64-linux-gnu/dri/swrast_dri.so "$APPDIR/usr/lib/dri/"
test -e "$APPDIR/usr/lib/libmpv.so.2" || { echo "libmpv.so.2 was not bundled" >&2; exit 1; }

ARCH=x86_64 appimagetool --no-appstream "$APPDIR" "$OUT/Mydia_Player-x86_64.AppImage"
echo "Built $OUT/Mydia_Player-x86_64.AppImage"
