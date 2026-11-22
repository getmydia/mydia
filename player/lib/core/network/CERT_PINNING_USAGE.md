# Certificate Pinning Usage Guide

This guide shows how to use the certificate pinning implementation for secure connections to Mydia instances using self-signed certificates.

## Overview

The certificate pinning implementation consists of four main components:

1. **CertStorage** (`lib/core/auth/cert_storage.dart`) - Stores certificate fingerprints securely
2. **CertVerifier** (`lib/core/network/cert_verifier.dart`) - Verifies certificates and manages fingerprints
3. **PinnedHttpClient** (`lib/core/network/pinned_http_client.dart`) - Creates HTTP clients with certificate validation
4. **CertTrustDialog** (`lib/presentation/widgets/cert_trust_dialog.dart`) - Shows TOFU dialog for first connections

## Basic Usage

### 1. First Connection (Trust On First Use)

When connecting to a server for the first time with a self-signed certificate:

```dart
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/network/pinned_http_client.dart';
import 'package:player/core/auth/cert_storage.dart';
import 'package:player/presentation/widgets/cert_trust_dialog.dart';

Future<void> connectToServer(
  BuildContext context,
  String serverUrl,
  String instanceId,
) async {
  final pinnedClient = PinnedHttpClient();
  final certStorage = CertStorage();

  // Create client that will capture the certificate
  X509Certificate? capturedCert;
  final client = await pinnedClient.createClient(
    instanceId,
    onUnknownCertificate: (cert, fingerprint) async {
      capturedCert = cert;
      return true; // Temporarily accept to capture cert
    },
  );

  try {
    // Make initial connection
    final request = await client.getUrl(Uri.parse(serverUrl));
    final response = await request.close();

    if (capturedCert != null) {
      // Compute fingerprint for display
      final fingerprint = PinnedHttpClient.computeFingerprint(capturedCert!);

      // Show trust dialog
      final trusted = await showCertTrustDialog(
        context,
        serverUrl,
        fingerprint,
      );

      if (trusted == true) {
        // User trusts the certificate - store fingerprint
        await certStorage.storeFingerprint(instanceId, fingerprint);
      } else {
        // User rejected - close connection
        client.close();
        throw Exception('Certificate not trusted');
      }
    }
  } finally {
    client.close();
  }
}
```

### 2. Subsequent Connections (Pinned)

After the fingerprint is stored, subsequent connections will automatically verify:

```dart
Future<void> makeSecureRequest(String instanceId, String url) async {
  final pinnedClient = PinnedHttpClient();

  // Client will automatically verify certificate against stored fingerprint
  final client = await pinnedClient.createClient(instanceId);

  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();

    // Connection is secure and certificate is verified
    // ... process response
  } on HandshakeException {
    // Certificate mismatch or validation failed
    throw Exception('Certificate validation failed');
  } finally {
    client.close();
  }
}
```

### 3. Managing Stored Fingerprints

```dart
final certStorage = CertStorage();

// Check if fingerprint exists
final fingerprint = await certStorage.getFingerprint(instanceId);
if (fingerprint != null) {
  print('Stored fingerprint: $fingerprint');
}

// Remove fingerprint (e.g., when user logs out or changes servers)
await certStorage.removeFingerprint(instanceId);

// Clear all fingerprints
await certStorage.clearAll();
```

## Integration with Auth Service

You should integrate certificate pinning with the login flow:

```dart
class AuthService {
  final CertStorage _certStorage = CertStorage();

  Future<void> clearSession() async {
    final serverUrl = await getServerUrl();

    // Clear auth data
    await clearToken();
    await clearServerUrl();

    // Also clear stored certificate fingerprint
    if (serverUrl != null) {
      await _certStorage.removeFingerprint(serverUrl);
    }
  }
}
```

## Instance ID Recommendations

Use a consistent instance ID strategy across the app:

- **Recommended**: Use the normalized server URL as the instance ID
- **Alternative**: Use a device/pairing ID if you have one

Example:
```dart
String getInstanceId(String serverUrl) {
  // Normalize URL (remove trailing slash, etc.)
  final normalized = serverUrl.endsWith('/')
      ? serverUrl.substring(0, serverUrl.length - 1)
      : serverUrl;
  return normalized;
}
```

## Security Considerations

1. **Fingerprint Storage**: Fingerprints are stored using FlutterSecureStorage (encrypted on native platforms)
2. **TOFU Model**: Users must trust the certificate on first connection
3. **Fingerprint Format**: SHA-256 hash in colon-separated hex (e.g., "aa:bb:cc:...")
4. **Certificate Changes**: If the server certificate changes, the connection will fail and require re-trust

## Error Handling

```dart
try {
  await makeSecureRequest(instanceId, url);
} on HandshakeException catch (e) {
  // Certificate validation failed
  // Show error and option to re-trust
  print('Certificate validation failed: $e');
} on SocketException catch (e) {
  // Network error
  print('Network error: $e');
}
```

## Testing

For testing with self-signed certificates in development:

1. First connection will show the trust dialog
2. Accept the certificate to store the fingerprint
3. Subsequent connections will verify automatically
4. To reset: `await certStorage.clearAll()`
