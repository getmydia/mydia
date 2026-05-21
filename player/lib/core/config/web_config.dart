/// Web configuration for the Mydia player.
///
/// On web platform, Phoenix injects auth configuration into window.mydiaConfig.
/// This allows the Flutter web player to auto-authenticate without manual login.
library;

import 'web_config_stub.dart' if (dart.library.js_interop) 'web_config_web.dart'
    as impl;

/// Configuration injected by Phoenix for web auto-authentication.
class MydiaWebConfig {
  final bool authenticated;
  final String? token;
  final String? userId;
  final String? username;
  final String? serverUrl;
  final bool embedMode;

  const MydiaWebConfig({
    required this.authenticated,
    this.token,
    this.userId,
    this.username,
    this.serverUrl,
    this.embedMode = false,
  });

  /// Check if this config has valid auth data.
  bool get hasValidAuth =>
      authenticated && token != null && token!.isNotEmpty && serverUrl != null;
}

/// Get the web configuration injected by Phoenix.
///
/// Returns null on non-web platforms or if no config was injected.
MydiaWebConfig? getWebConfig() => impl.getWebConfig();

/// Check if running on web platform.
bool get isWebPlatform => impl.isWebPlatform;

/// Get the current origin URL (for web platform).
///
/// Returns null on non-web platforms.
String? getOriginUrl() => impl.getOriginUrl();

/// Check if running in embed mode (served from /player).
///
/// In embed mode, the player should show a link back to the main Mydia app.
bool get isEmbedMode {
  final config = getWebConfig();
  return config?.embedMode ?? false;
}

/// Get the URL to the main Mydia app.
///
/// Returns the origin URL without the /player path.
String? getMydiaAppUrl() {
  final origin = getOriginUrl();
  if (origin == null) return null;
  return origin;
}

/// Navigate to the main Mydia app.
///
/// On web, this navigates the browser to the main app URL.
/// On non-web platforms, this is a no-op.
void navigateToMydiaApp() => impl.navigateToMydiaApp();
