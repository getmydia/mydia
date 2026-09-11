# Remote Access

Remote access allows the Mydia mobile app to connect to your Mydia instance from anywhere, even when your server is behind NAT or a firewall.

## Get the Mobile App

The Mydia player is distributed through TestFlight. Install the [TestFlight app](https://apps.apple.com/app/testflight/id899247664) on your iPhone or iPad, then use the link below. Each new release reaches you automatically.

[Install on iOS](https://testflight.apple.com/join/KFSYxaQP){ .md-button .md-button--primary }

### Pre-release builds

There is a second TestFlight track carrying release candidates and betas
alongside every stable release, for anyone who wants to try changes early and
report problems before they ship. It is the same opt-in as the Docker `:beta`
tag and the Flatpak beta channel, and it moves faster and breaks more often.

[Install pre-release builds](https://testflight.apple.com/join/XTvarNBK){ .md-button }

Pick one. Joining the pre-release track does not remove you from the stable one,
so opening both links leaves you a member of both. Leaving a track again is done
from inside the TestFlight app, not from these links.

## Configuration

### Enable Remote Access

Remote access is on by default. Switch it off or back on under **Admin ›
Configuration › Remote Access**; the p2p node stops or starts right away, with no
restart.

To pin it from the environment instead, set `ENABLE_REMOTE_ACCESS=true` or
`ENABLE_REMOTE_ACCESS=false` on the container. The variable wins over the toggle,
which then shows an **ENV** badge and cannot be changed.

`ENABLE_PLAYER=false` turns off the whole player, remote access included.

Optionally set `P2P_BIND_PORT` to a fixed UDP port and forward it, which lets peers
hole-punch a direct connection instead of falling back to a relay. See
[Environment Variables](../reference/environment-variables.md) for all three.

### Direct URLs

Direct URLs are automatically detected from your instance's network configuration:
- Local IP addresses (e.g., `https://192.168.1.100:4443`)
- Public hostname (if configured)
- Custom domain (if configured)

## Pairing a Device

Pairing uses a **claim code**: a short, single-use code (shown as a QR code or as
eight characters) that you generate on your instance and enter in the player. It
stands in for your instance's cryptographic node identity, which is far too long
to type, and it is valid for **five minutes** and one use only. After pairing,
the device holds a long-lived device token and the code is no longer involved.

To generate one, open **Devices** from the sidebar and use **Pair a new device**.
Your paired devices are listed on the same page, where you can revoke them
individually or clear the inactive ones.

See [How Remote Access Works](../explanation/remote-access.md#claim-codes) for
why the window is so short.

## Troubleshooting

### App won't connect

1. **Check remote access is on** - the toggle under Admin > Configuration > Remote
   Access. If the tab is missing, the whole player is off: `ENABLE_PLAYER=false`
2. **Verify p2p server is running** - check logs for startup messages
3. **Generate a fresh claim code** - codes expire five minutes after you create
   them and cannot be reused, so a code left on screen while you fetched your
   phone is likely already expired

### Slow performance

1. **Check connection type** - a connection that stayed on the relay is slower
   than one that hole-punched through to a direct path
2. **Network issues** - try from different network to isolate
3. **Firewall rules** - ensure outbound UDP is allowed for QUIC

### Connection drops

The p2p stack handles reconnection automatically:

1. **Transient failures** - automatic retry with backoff
2. **Network change** - reconnection after network switch
3. **Long disconnects** - may require re-pairing

The retry and path-selection logic lives in the player, not the server. See
[API Reference](../reference/api.md#connection-manager) for where to find it.

## Next Steps

- [How Remote Access Works](../explanation/remote-access.md) - The peer-to-peer design, what infrastructure it depends on, and why claim codes expire so quickly
