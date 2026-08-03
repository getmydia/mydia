import 'dart:ui';

/// The desktop window's persisted geometry.
///
/// [bounds] is always the *un-maximized* rect. `windowManager.getBounds()`
/// returns the maximized frame while maximized, so a tracker that wrote that
/// would destroy the user's real window size the first time they ever
/// maximized. See `WindowGeometryController`.
///
/// Serialized as a plain map rather than a generated Hive adapter, matching
/// `LocalPlaybackProgress`: no build_runner step, and no type id to claim.
class WindowGeometry {
  final Rect bounds;
  final bool maximized;

  const WindowGeometry({required this.bounds, required this.maximized});

  WindowGeometry copyWith({Rect? bounds, bool? maximized}) => WindowGeometry(
        bounds: bounds ?? this.bounds,
        maximized: maximized ?? this.maximized,
      );

  Map<String, dynamic> toMap() => {
        'x': bounds.left,
        'y': bounds.top,
        'width': bounds.width,
        'height': bounds.height,
        'maximized': maximized,
      };

  /// Throws [FormatException] on anything unreadable. The store catches and
  /// discards, which is the same split `HivePlaybackProgressStore` uses.
  factory WindowGeometry.fromMap(Map<dynamic, dynamic> map) {
    final width = _readNumber(map, 'width');
    final height = _readNumber(map, 'height');

    // Coordinates may legitimately be negative — a display arranged left of or
    // above the primary has negative global origins. Sizes may not.
    if (width <= 0 || height <= 0) {
      throw FormatException('Non-positive window size: ${width}x$height');
    }

    final maximized = map['maximized'];
    if (maximized is! bool) {
      throw FormatException('Expected bool for "maximized", got $maximized');
    }

    return WindowGeometry(
      bounds: Rect.fromLTWH(
        _readNumber(map, 'x'),
        _readNumber(map, 'y'),
        width,
        height,
      ),
      maximized: maximized,
    );
  }

  /// Hive may hand back a whole double as an `int`, so read `num` and widen
  /// rather than casting to `double` and throwing on a valid record.
  static double _readNumber(Map<dynamic, dynamic> map, String key) {
    final value = map[key];
    if (value is! num) {
      throw FormatException('Expected number for "$key", got $value');
    }
    return value.toDouble();
  }
}
