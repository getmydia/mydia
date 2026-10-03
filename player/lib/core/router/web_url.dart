// Web-specific URL handling using package:web and dart:js_interop
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Gets the initial route from the browser's URL hash.
/// Returns the hash without the leading '#', or '/' if no hash is present.
///
/// Phoenix injects `window.mydiaInitialHash` before Flutter loads to capture
/// the hash before any potential timing issues with dart:html's window.location.
String getInitialRoute() {
  // First, try to read the hash that Phoenix captured before Flutter loaded
  final phoenixHash =
      globalContext.getProperty<JSString?>('mydiaInitialHash'.toJS)?.toDart;

  // Also try direct access as fallback
  final hash = web.window.location.hash;
  final href = web.window.location.href;

  // Use Phoenix-captured hash first, then fallback to direct access
  String effectiveHash = '';

  if (phoenixHash != null && phoenixHash.isNotEmpty) {
    effectiveHash = phoenixHash;
  } else if (hash.isNotEmpty) {
    effectiveHash = hash;
  } else if (href.contains('#')) {
    final hashIndex = href.indexOf('#');
    effectiveHash = href.substring(hashIndex);
  }

  if (effectiveHash.isNotEmpty && effectiveHash.length > 1) {
    // Remove the leading '#' from the hash
    return effectiveHash.substring(1);
  }
  return '/';
}
