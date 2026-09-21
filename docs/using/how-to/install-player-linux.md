# Install the player on Linux

Mydia Player is distributed as a Flatpak. The Flatpak bundles its own media
stack, so nothing else needs installing.

## Stable

```bash
flatpak remote-add --if-not-exists --from mydia https://flatpak.mydia.dev/mydia.flatpakrepo
flatpak install mydia dev.mydia.player
flatpak run dev.mydia.player
```

The player updates itself. When a new build reaches the remote you installed
from, Settings offers to install it and then to restart. `flatpak update` and
your desktop's software centre keep working exactly as before; nothing has to
be done in the app.

## Beta

Beta tracks prereleases. It is the same application on a different remote and
branch, so switch between the two rather than keeping both installed. Your
settings and sign-in live outside the install and carry over either way.

To switch to beta:

```bash
flatpak remote-add --if-not-exists --from mydia-beta https://flatpak.mydia.dev/mydia-beta.flatpakrepo
flatpak install mydia-beta dev.mydia.player//beta
flatpak uninstall dev.mydia.player//stable
```

To move back to stable:

```bash
flatpak remote-add --if-not-exists --from mydia https://flatpak.mydia.dev/mydia.flatpakrepo
flatpak install mydia dev.mydia.player//stable
flatpak uninstall dev.mydia.player//beta
```

Installing a branch makes it the one your desktop launches, which is why the
old branch can go straight after. On a fresh install, stop after the second
command. **Settings › Manage › Release track** in the app shows the same
commands.

## Tarball

Every release also carries `mydia-player-linux-vX.Y.Z.tar.gz` for systems
without Flatpak. Unlike the Flatpak, it links your system libmpv, so install
that first or the binary will not start.

```bash
# Debian and Ubuntu
sudo apt install libmpv2

# Fedora
sudo dnf install mpv-libs

# Arch
sudo pacman -S mpv
```

Then unpack the archive and run `./mydia-player`.

## Troubleshooting

If the application starts and immediately exits, run it from a terminal. A
message naming a missing shared library means you are on the tarball without
libmpv installed, and the Flatpak is the fix.

If video plays but a particular file shows a black screen, the codec extension
may not have installed. Check for it and add it if missing:

```bash
flatpak list | grep codecs-extra
flatpak install org.freedesktop.Platform.codecs-extra//25.08-extra
```
