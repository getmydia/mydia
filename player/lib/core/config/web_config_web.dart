/// Web-specific implementation using dart:js_interop.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

import 'web_config.dart';

/// Get the web configuration injected by Phoenix.
///
/// Reads window.mydiaConfig which is set by the Phoenix player controller.
MydiaWebConfig? getWebConfig() {
  try {
    final configObj = web.window['mydiaConfig'];
    if (configObj.isUndefinedOrNull) return null;

    final config = configObj;

    final authenticatedVal = config['authenticated'];
    if (authenticatedVal.isUndefinedOrNull) {
      return null;
    }

    final authenticated = (authenticatedVal as JSBoolean).toDart;
    final embedModeVal = config['embedMode'];
    final embedMode = !embedModeVal.isUndefinedOrNull
        ? (embedModeVal as JSBoolean).toDart
        : false;

    final localeVal = config['locale'];
    final locale =
        !localeVal.isUndefinedOrNull ? (localeVal as JSString).toDart : null;

    if (!authenticated) {
      return MydiaWebConfig(
          authenticated: false, embedMode: embedMode, locale: locale);
    }

    final tokenVal = config['token'];
    final userIdVal = config['userId'];
    final usernameVal = config['username'];

    return MydiaWebConfig(
      authenticated: true,
      token: !tokenVal.isUndefinedOrNull ? (tokenVal as JSString).toDart : null,
      userId:
          !userIdVal.isUndefinedOrNull ? userIdVal.dartify()?.toString() : null,
      username: !usernameVal.isUndefinedOrNull
          ? (usernameVal as JSString).toDart
          : null,
      serverUrl: getOriginUrl(),
      embedMode: embedMode,
      locale: locale,
    );
  } catch (e) {
    // If parsing fails, return null
    return null;
  }
}

/// Running on web platform.
bool get isWebPlatform => true;

/// Get the current origin URL from window.location.
String? getOriginUrl() {
  try {
    return web.window.location.origin;
  } catch (e) {
    return null;
  }
}

/// Navigate to the main Mydia app.
void navigateToMydiaApp() {
  try {
    final origin = web.window.location.origin;
    web.window.location.href = origin;
  } catch (_) {
    // Ignore navigation errors
  }
}
