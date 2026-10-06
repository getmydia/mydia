# Connection Management

This directory contains the connection management infrastructure for establishing connections to Mydia instances using a **relay-first, hot-swap-to-direct** strategy.

## Overview

The connection strategy prioritizes:

1. **Immediate connectivity** via relay tunnel (works regardless of network topology)
2. **Optimal performance** via transparent hot swap to direct connection when available
3. **Reliability** via automatic fallback to relay if direct connection drops

## Connection State Machine

```
                    ┌─────────────┐
                    │   Initial   │
                    └──────┬──────┘
                           │ connect via relay
                           v
                    ┌─────────────┐
                    │  RelayOnly  │◄──────────────────────┐
                    └──────┬──────┘                       │
                           │ probe succeeds               │ direct drops
                           v                              │
                    ┌─────────────┐                       │
                    │    Dual     │───────────────────────┤
                    └──────┬──────┘                       │
                           │ relay requests drained       │
                           v                              │
                    ┌─────────────┐                       │
                    │ DirectOnly  │───────────────────────┘
                    └─────────────┘
```

### States

- **RelayOnly**: Initial state, all traffic flows through relay tunnel
- **Dual**: Hot swap in progress; new requests go to direct, in-flight relay requests continue
- **DirectOnly**: All traffic flows through direct connection; relay tunnel closed

## Components

### `connection_result.dart`

Result types for connection operations:

- `ConnectionResult` - Wraps connection attempt results
- `ConnectionType` - Enum for `direct` or `relay` connections
- `ConnectionMode` - Enum for state machine states (`relayOnly`, `directOnly`, `dual`)
- `ConnectionState` - Full state including pending request counts, probe status

### `relay_first_connection_manager.dart`

The main orchestrator implementing the relay-first strategy:

- **State management**: Tracks current mode and pending requests
- **Request routing**: Routes requests based on current state
- **Hot swap**: Coordinates transition from relay to direct
- **Auto-fallback**: Automatically reconnects via relay if direct drops
- **Request queuing**: Queues requests during reconnection

### `direct_prober.dart`

Background service for testing direct URL connectivity:

- **Probe sequence**: TCP connection → TLS handshake → Phoenix channel join
- **Exponential backoff**: 5s, 10s, 30s, 60s, max 5min between retries
- **App lifecycle awareness**: Re-probes on app foreground
- **Network change detection**: Immediate re-probe on network change

## Hot Swap Behavior

When a direct probe succeeds:

1. State transitions to `Dual` mode
2. New requests are routed to direct connection
3. In-flight relay requests continue on relay
4. Once all relay requests complete, relay tunnel is closed
5. State transitions to `DirectOnly` mode

This ensures zero dropped requests during the transition.

## Auto-Fallback Behavior

When direct connection drops:

1. Request queue is activated (new requests wait)
2. Reconnection via relay begins with exponential backoff
3. On success, state returns to `RelayOnly`
4. Queued requests are processed
5. Background probing restarts

## Integration with PairingService

The `PairingService` now uses relay-first strategy:

```dart
// PairingService.pairWithClaimCodeOnly()
Future<PairingResult> pairWithClaimCodeOnly({...}) async {
  // Step 1: Look up claim code via relay
  final lookupResult = await _relayService.lookupClaimCode(claimCode);

  // Step 2: Always connect via relay tunnel (relay-first strategy)
  return await _pairViaRelayTunnel(
    claimCode: claimCode,
    claimInfo: claimInfo,
    serverPublicKey: serverPublicKey,
    deviceName: deviceName,
    devicePlatform: devicePlatform,
  );

  // Background probing for direct URLs starts automatically
  // Hot swap occurs transparently when direct probe succeeds
}
```

## Probe Frequency

| Event | Probe Timing |
|-------|--------------|
| Initial connection | Immediate |
| Probe failure | Exponential backoff (5s → 10s → 30s → 60s → 5min) |
| Network change | Immediate |
| App foreground | Immediate (if on relay) |
| App background | Paused |

## Troubleshooting

### Stuck on relay

If the app stays on relay even when direct should work:

1. Check that direct URLs in stored credentials are correct
2. Verify network allows outbound connections to direct URLs
3. Check if certificate fingerprint verification is failing
4. Look for "Probe failed" messages in debug output

### Request failures during reconnection

If requests fail during direct → relay fallback:

1. Requests are queued during reconnection (up to 5 retries)
2. If reconnection fails, queued requests are failed with error
3. UI should handle request failures gracefully

### Connection indicator shows wrong state

The UI indicator reflects the `connectionProvider` state, which should update when:

- Initial connection completes (relay or direct)
- Hot swap completes (relay → direct)
- Fallback completes (direct → relay)

## Dependencies

- `ChannelService` - Phoenix WebSocket connections
- `RelayTunnelService` - Relay WebSocket tunnels
- `CryptoManager` - X25519 key exchange
- `AuthStorage` - Credential persistence
