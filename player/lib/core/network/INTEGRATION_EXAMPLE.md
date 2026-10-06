# Certificate Pinning Integration Example

This document shows how to integrate certificate pinning into the connection workflow for WebSocket and HTTP connections.

## WebSocket Integration (Phoenix Channels)

The `ChannelService` uses the `phoenix_socket` package which doesn't directly expose certificate validation callbacks. Here's the recommended integration strategy:

### Step 1: Pre-flight Certificate Check

Before establishing a WebSocket connection, perform a quick HTTPS request to the same server to capture and verify the certificate:

```dart
import 'dart:io';
import 'package:player/core/network/cert_verifier.dart';
import 'package:player/core/network/pinned_http_client.dart';
import 'package:player/core/channels/channel_service.dart';

Future<bool> verifyAndStoreServerCertificate(
  BuildContext context,
  String serverUrl,
  String instanceId,
) async {
  final verifier = CertVerifier();
  X509Certificate? serverCert;

  // Create HTTP client to capture certificate
  final client = HttpClient();
  client.badCertificateCallback = (cert, host, port) {
    serverCert = cert;
    return true; // Temporarily accept to capture
  };

  try {
    // Make a simple request to capture the certificate
    final request = await client.getUrl(Uri.parse(serverUrl));
    await request.close();

    if (serverCert != null) {
      // Verify the certificate
      final result = await verifier.verifyCertificate(serverCert!, instanceId);

      if (result.verified && !result.firstTime) {
        // Certificate matches stored fingerprint
        return true;
      } else if (result.firstTime) {
        // First connection - show TOFU dialog
        final trusted = await showCertTrustDialog(
          context,
          serverUrl,
          result.fingerprint,
        );

        if (trusted == true) {
          await verifier.trustCertificate(serverCert!, instanceId);
          return true;
        }
        return false;
      } else {
        // Certificate mismatch
        throw Exception('Certificate verification failed: ${result.error}');
      }
    }

    throw Exception('Could not capture server certificate');
  } finally {
    client.close();
  }
}
```

### Step 2: Integrate into Pairing Flow

Update the `PairingService` to verify certificates before connecting:

```dart
// In pairing_service.dart

Future<PairingResult> pairWithClaimCodeOnly({
  required String claimCode,
  required String deviceName,
  String? platform,
  void Function(String status)? onStatusUpdate,
  required BuildContext context, // Add context for dialog
}) async {
  try {
    // ... existing lookup code ...

    // NEW: Verify certificate before connecting
    onStatusUpdate?.call('Verifying server certificate...');
    final certVerified = await verifyAndStoreServerCertificate(
      context,
      connectedUrl,
      connectedUrl, // Use URL as instance ID
    );

    if (!certVerified) {
      return PairingResult.error('Server certificate not trusted');
    }

    // Continue with existing connection flow...
    final connectResult = await _channelService.connect(connectedUrl);
    // ...
  }
}
```

## HTTP Client Integration

For direct HTTP/HTTPS requests, use the `PinnedHttpClient`:

```dart
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:player/core/network/pinned_http_client.dart';

Future<http.Response> makeAuthenticatedRequest(
  String url,
  String instanceId,
) async {
  final pinnedClient = PinnedHttpClient();
  final httpClient = await pinnedClient.createClient(instanceId);

  try {
    // Wrap the HttpClient in an IOClient for use with the http package
    final client = IOClient(httpClient);
    final response = await client.get(Uri.parse(url));
    return response;
  } finally {
    httpClient.close();
  }
}
```

## Complete Example: First Connection Flow

Here's a complete example showing the full TOFU workflow:

```dart
Future<void> connectToNewServer(
  BuildContext context,
  String serverUrl,
) async {
  final instanceId = serverUrl;
  final verifier = CertVerifier();

  // Step 1: Check if we already trust this server
  final existing = await verifier.getStoredFingerprint(instanceId);
  if (existing == null) {
    // Step 2: First connection - capture and verify certificate
    final certVerified = await verifyAndStoreServerCertificate(
      context,
      serverUrl,
      instanceId,
    );

    if (!certVerified) {
      throw Exception('Certificate not trusted');
    }
  }

  // Step 3: Create pinned clients for all connections
  final httpClient = await PinnedHttpClient().createClient(instanceId);

  // Step 4: Use the pinned client for all requests
  // WebSocket connection (already verified in step 2)
  await ChannelService().connect(serverUrl);

  // HTTP requests
  final ioClient = IOClient(httpClient);
  // ... use ioClient for requests
}
```

## Security Notes

1. **Always verify before first WebSocket connection**: Phoenix Socket doesn't provide certificate callbacks, so verify using HTTP first
2. **Store fingerprints by URL**: Use the server URL as the instance ID for consistency
3. **Re-verify on certificate change**: If the server certificate changes, the stored fingerprint won't match and connection will fail
4. **Clear fingerprints on logout**: When the user logs out or switches servers, clear the stored fingerprint

## Implementation Status

As of this implementation:

- ✅ `CertVerifier` - Standalone certificate verification service
- ✅ `CertStorage` - Secure fingerprint storage
- ✅ `PinnedHttpClient` - HTTP client factory with pinning
- ✅ `CertTrustDialog` - TOFU user interface
- ⚠️ WebSocket integration - Requires pre-flight HTTP check (documented above)

## Testing

Due to FlutterSecureStorage requiring native platform, unit tests need mocking. Use Mockito to mock FlutterSecureStorage in your tests.

For integration testing, test with a real development server using self-signed certificates:

1. Start server with self-signed cert
2. Connect from app - TOFU dialog should appear
3. Accept certificate
4. Subsequent connections should succeed without dialog
5. Change server certificate - connection should fail
