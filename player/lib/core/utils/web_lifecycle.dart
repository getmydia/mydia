// Web lifecycle utilities for handling browser events.
// Uses conditional imports to provide web-specific functionality
// while remaining compatible with non-web platforms.
export 'web_lifecycle_stub.dart'
    if (dart.library.js_interop) 'web_lifecycle_web.dart';
