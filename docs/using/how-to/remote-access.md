# Remote Access

Remote access allows the Mydia mobile app to connect to your Mydia instance from anywhere, even when your server is behind NAT or a firewall.

## Get the Mobile App (iOS Beta)

The Mydia player is in open beta on TestFlight. Install the [TestFlight app](https://apps.apple.com/app/testflight/id899247664) on your iPhone or iPad, then join the beta. New builds reach you automatically as they ship.

[Join the iOS Beta](https://testflight.apple.com/join/KFSYxaQP){ .md-button .md-button--primary }

## How It Works

Mydia uses **p2p** for decentralized peer-to-peer connectivity:

1. **Discovery**: Nodes find each other via mDNS (local network) and Kademlia DHT (internet)
2. **Transport**: Connections are established over TCP or QUIC, secured with Noise encryption
3. **Media**: Media streams (HLS) are served over the p2p connection via a local proxy in the client

This approach provides:
- **Decentralized**: No central relay dependency for connectivity
- **NAT Traversal**: Built-in hole punching and relay capabilities
- **Performance**: Direct peer-to-peer connections when possible
- **Reliability**: Multiple transport options and automatic fallback

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

## Security

### Encryption

All communication is encrypted end-to-end using the Noise protocol:

- **Transport**: All p2p connections use Noise encryption
- **Authentication**: Peers authenticate via Ed25519 keys
- **Forward Secrecy**: Fresh ephemeral keys for each connection

### Authentication

- Initial pairing uses claim codes (QR code or 6-digit code)
- Subsequent connections use device tokens with key exchange
- Each session establishes fresh encryption keys

### Certificate Verification

For direct HTTPS connections, the app verifies the server's TLS certificate fingerprint against the fingerprint stored during pairing, preventing man-in-the-middle attacks.

## Architecture Details

### P2P Components

The p2p implementation is shared between backend and frontend:

- **Core (Rust)**: `native/mydia_p2p_core` - shared networking logic
- **Backend (Elixir)**: Wrapped via Rustler NIF (`Mydia.P2p`)
- **Frontend (Flutter)**: Wrapped via `flutter_rust_bridge`

### Protocols Used

| Protocol | Purpose |
|----------|---------|
| mDNS | Local network discovery |
| Kademlia DHT | Internet-wide peer discovery |
| TCP/QUIC | Transport layer |
| Noise | Encryption and authentication |

### Instance Registration

When remote access is enabled, your Mydia instance:
1. Starts the p2p server
2. Announces itself via mDNS and DHT
3. Listens for incoming peer connections
4. Handles connection requests from paired devices

### Client Connection

When the app connects:
1. Discovers the instance via mDNS or DHT lookup
2. Establishes p2p connection (TCP or QUIC)
3. Completes Noise handshake for authentication
4. Routes API and media requests over the secure connection

## Troubleshooting

### App won't connect

1. **Check remote access is enabled** on your Mydia instance
2. **Verify p2p server is running** - check logs for startup messages
3. **Check claim code** - codes expire after 5 minutes

### Slow performance

1. **Check connection type** - DHT discovery may take longer than mDNS
2. **Network issues** - try from different network to isolate
3. **Firewall rules** - ensure UDP ports are open for QUIC

### Connection drops

The p2p stack handles reconnection automatically:

1. **Transient failures** - automatic retry with backoff
2. **Network change** - reconnection after network switch
3. **Long disconnects** - may require re-pairing

## API Reference

### Connection Manager API

See `player/lib/core/connection/README.md` for Flutter implementation details.
