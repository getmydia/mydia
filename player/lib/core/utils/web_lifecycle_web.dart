// Web implementation for lifecycle events.
import 'dart:js_interop';

import 'package:web/web.dart' as web;

typedef BeforeUnloadCallback = void Function();

BeforeUnloadCallback? _currentCallback;

final JSFunction _listener = ((web.Event _) {
  _currentCallback?.call();
}).toJS;

/// Register a callback to be called before the page unloads.
/// On web, this listens to the 'beforeunload' event.
void registerBeforeUnload(BeforeUnloadCallback callback) {
  _currentCallback = callback;
  web.window.addEventListener('beforeunload', _listener);
}

/// Unregister the beforeunload callback.
void unregisterBeforeUnload() {
  web.window.removeEventListener('beforeunload', _listener);
  _currentCallback = null;
}
