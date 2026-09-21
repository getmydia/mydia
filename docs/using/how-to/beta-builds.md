# Try beta builds

<!-- Section ids are pinned: the download page (site/src/pages/download.astro)
     links to each one by its card id. Rename a heading freely, but keep the id. -->

Beta builds are prereleases of Mydia Player, tagged `-beta.N` or `-rc.N`. They
arrive a few weeks ahead of the stable release and get less testing, so expect
the occasional rough edge. Every install starts on stable, and joining a beta
is a choice you make on each device.

If something breaks, [open an issue](https://github.com/getmydia/mydia/issues)
and include the version shown in Settings. A beta player can be newer than
your Mydia server. When it needs a newer server than the one you run, the app
tells you.

## Going back to stable

On Android, macOS, Windows and the Linux tarball, choose **Stable** in the same
Release track setting you used to join. Nothing is downgraded: the beta you
have stays installed until a stable release passes it. To leave the beta
straight away, reinstall from the [download page](https://mydia.dev/download).
iOS and the Flatpak work differently, and their sections below say how.

## Android { #android }

Open **Settings › Manage › Release track** and choose **Beta**. Betas then
arrive the same way stable updates do.

This applies to the APK from the [download page](https://mydia.dev/download#android).
A copy installed from Google Play has no Release track setting. The same list
also offers **Dev**, built straight from development and rougher than beta.

## iOS { #ios }

Betas and release candidates have their own TestFlight group. With the
[TestFlight app](https://apps.apple.com/app/testflight/id899247664) installed,
join it here:

[Install pre-release builds](https://testflight.apple.com/join/XTvarNBK){ .md-button }

Joining the pre-release group does not remove you from the stable one, so you
end up a member of both. Leaving a group again is done from inside the
TestFlight app, not from this link.

## macOS { #macos }

Open **Settings › Manage › Release track** and choose **Beta**. The app offers
betas alongside stable updates from then on.

## Windows { #windows }

Open **Settings › Manage › Release track** and choose **Beta**.

## Linux { #linux }

The Flatpak's beta lives on a separate remote, `mydia-beta`. Adding it,
installing from it, and moving back to stable are covered in
[Install the player on Linux](install-player-linux.md#beta).

The tarball works like Windows: open **Settings › Manage › Release track** and
choose **Beta**.

## Web { #web }

The web player has no beta of its own. The copy at `/player` on your server is
whatever version your Mydia server runs, so it becomes a beta when the server
does. [Updating Mydia](update-mydia.md#testing-pre-release-builds) covers the
server's `:beta` image. The public web player at web.mydia.dev only ever runs
stable.
