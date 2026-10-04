# Connect Plex, Jellyfin or Stash

!!! warning "Experimental"
    Connecting the player to Plex, Jellyfin and Stash servers is new. It may
    change or break between releases. If something goes wrong, please
    [open an issue](https://github.com/getmydia/mydia/issues). Mydia remains
    the server the player is built around, and some features only work there.

Mydia Player can browse and play from Plex, Jellyfin and Stash servers
alongside your Mydia library. Each server you add shows up in the source
switcher, and you can move between them at any time.

## Before you start

- Use the desktop or mobile app. The web player at `/player` cannot add
  these servers.
- You do not need a Mydia server. If the player opens on the Mydia login
  screen, tap **Connect another server instead**.

## Add a server

Open **Add a server** in any of these ways:

- **Add server** in the source switcher.
- Settings, **Plex, Jellyfin and Stash** (under Other servers), then
  **Add server**.
- **Connect another server instead** on the login screen.

Then pick the kind of server.

### Plex

1. Choose **Plex**. The player shows a code.
2. Go to [plex.tv/link](https://plex.tv/link) on any device and enter the
   code, or tap **Open plex.tv/link** to do it on this one.
3. Under **Choose servers to add**, pick the servers you want and confirm.

Servers other Plex users share with you can be added too.

### Jellyfin

1. Choose **Jellyfin** and enter the **Server address**, for example
   `http://192.168.1.30:8096`.
2. If the server has Quick Connect turned on, the player shows a code.
   Approve it in Jellyfin under Settings, Quick Connect.
3. Otherwise, or if you prefer, tap **Use a password instead** and sign in
   with your **Username** and **Password**.

### Stash

1. Choose **Stash** and enter the **Server address**, for example
   `http://192.168.1.20:9999`.
2. If your Stash requires a login, paste its API key into
   **API key (if Stash asks for a login)**. Stash shows the key, or lets you
   generate one, under Settings, Security.

## Switch Plex Home users

If your Plex account has Home users, open Settings, **Plex, Jellyfin and
Stash**, find the Plex account and choose **Switch user**. A user protected
by a PIN is asked for it every time; the player never stores it. Each user
sees the servers Plex shares with them.

## Manage or remove servers

Settings, **Plex, Jellyfin and Stash** lists every account you have added,
with its servers. From there you can add or remove servers, sign in again,
or remove the account. Removing an account only forgets it on this device.
Nothing changes on the server.

## What works

- Browsing each server's libraries.
- Continue Watching and the server's own home rows.
- Playback, with your position saved back to the server as you watch.
- Watched status: an item is marked watched on the server once you reach
  90%.

## What doesn't work yet

- Downloads for offline viewing.
- Casting to another device.
- Mydia's [remote access](remote-access.md). The player connects to these
  servers directly, trying the local address first, then remote ones, then
  Plex's relay for Plex. A server the player cannot reach directly will not
  work away from home.
