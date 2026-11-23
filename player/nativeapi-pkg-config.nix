# A `pkg-config` that finds GTK 3, X11 and Xi with no environment at all.
#
# window_manager and screen_retriever sit on nativeapi, whose cnativeapi build
# hook compiles a C++ core on every Linux `flutter test` and `flutter build
# linux`, and asks `pkg-config` for GTK 3, X11 and Xi. Flutter runs build
# hooks with a filtered environment (hooks_runner keeps PATH, HOME, NIX_* and
# a few others), so the PKG_CONFIG_PATH a Nix shell or derivation sets never
# reaches it, and the hook fails with "No package 'gtk+-3.0' found".
#
# This wrapper appends those packages' pkgconfig directories, including what
# they propagate (glib, pango, cairo, ...), to whatever PKG_CONFIG_PATH it is
# given, and completes queries for gtk+-3.0 and xi with two packages their
# headers need (see below). devenv.nix and nix/ci/player.nix put it on PATH
# ahead of pkgs.pkg-config. Hosts with a system pkg-config (Ubuntu CI, the Flatpak SDK)
# need none of this: their default search path already has the packages.
{ pkgs }:

let
  libs = [ pkgs.gtk3 pkgs.xorg.libX11 pkgs.xorg.libXi pkgs.xorg.libXext pkgs.xorg.libXfixes
    pkgs.wayland ];

  # stdenv's setup hooks collect the pkgconfig directories of buildInputs and
  # everything they propagate into a role-suffixed PKG_CONFIG_PATH_<platform>
  # variable, which the pkg-config wrapper hands to the real binary. Record
  # every PKG_CONFIG_PATH* variable, so the suffix need not be named here.
  searchPath = pkgs.runCommand "nativeapi-pkg-config-path"
    {
      nativeBuildInputs = [ pkgs.pkg-config ];
      buildInputs = libs;
    } ''
    # Fail here, not in a build hook later, if the set is incomplete.
    pkg-config --exists --print-errors gtk+-3.0 x11 xi xext xfixes wayland-client
    path=
    for v in ''${!PKG_CONFIG_PATH@}; do
      path="$path''${path:+:}''${!v}"
    done
    if [ -z "$path" ]; then
      echo "no PKG_CONFIG_PATH variable was set for the nativeapi libraries" >&2
      exit 1
    fi
    printf '%s' "$path" > $out
  '';
in
pkgs.writeShellScriptBin "pkg-config" ''
  extra=$(< ${searchPath})
  export PKG_CONFIG_PATH="''${PKG_CONFIG_PATH:+$PKG_CONFIG_PATH:}$extra"
  # Two headers nativeapi includes need a package the .pc files leave out,
  # since every Nix package has its own include directory where distribution
  # SDKs share /usr/include:
  #   gdk/gdkwayland.h includes wayland-client.h; gtk+-3.0.pc does not
  #     require wayland-client.
  #   X11/extensions/XInput2.h includes Xge.h (xext) and Xfixes.h (xfixes);
  #     xi.pc lists both only in Requires.private, which --cflags skips.
  # Only queries naming gtk+-3.0 or xi are completed.
  add=()
  for arg in "$@"; do
    case $arg in
      gtk+-3.0) add+=(wayland-client) ;;
      xi) add+=(xext xfixes) ;;
    esac
  done
  set -- "$@" "''${add[@]}"
  exec ${pkgs.pkg-config.pkg-config}/bin/pkg-config "$@"
''
