# Remote Access

Remote access allows the Mydia mobile app to connect to your Mydia instance from anywhere, even when your server is behind NAT or a firewall.

## Get the Mobile App (iOS Beta)

The Mydia player is in open beta on TestFlight. Install the [TestFlight app](https://apps.apple.com/app/testflight/id899247664) on your iPhone or iPad, then join the beta. New builds reach you automatically as they ship.

[Join the iOS Beta](https://testflight.apple.com/join/KFSYxaQP){ .md-button .md-button--primary }

## Configuration

### Enable Remote Access

1. Navigate to **Settings > Remote Access** in the Mydia web interface
2. Toggle **Enable Remote Access**
3. Your instance will start the p2p server and announce itself

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

See [How Remote Access Works](../explanation/remote-access.md#claim-codes) for
why the window is so short.

## Troubleshooting

### App won't connect

1. **Check remote access is enabled** on your Mydia instance
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

See [API Reference](../reference/api.md#connection-manager-api) for Connection Manager API details.

## Next Steps

- [How Remote Access Works](../explanation/remote-access.md) - The peer-to-peer design, what infrastructure it depends on, and why claim codes expire so quickly
