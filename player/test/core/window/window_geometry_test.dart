import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/window_geometry.dart';

void main() {
  group('WindowGeometry', () {
    test('round-trips through a map', () {
      const original = WindowGeometry(
        bounds: Rect.fromLTWH(100, 200, 1280, 800),
        maximized: true,
      );

      final restored = WindowGeometry.fromMap(original.toMap());

      expect(restored.bounds, original.bounds);
      expect(restored.maximized, original.maximized);
    });

    test('accepts negative coordinates', () {
      // A window on a display arranged to the left of, or above, the primary
      // has negative global coordinates. That is ordinary, not corrupt.
      const original = WindowGeometry(
        bounds: Rect.fromLTWH(-1920, -200, 1280, 800),
        maximized: false,
      );

      expect(WindowGeometry.fromMap(original.toMap()).bounds, original.bounds);
    });

    test('rejects a map missing a key', () {
      expect(
        () => WindowGeometry.fromMap(const {
          'x': 0.0,
          'y': 0.0,
          'width': 1280.0,
          // no height
          'maximized': false,
        }),
        throwsFormatException,
      );
    });

    test('rejects a value of the wrong type', () {
      expect(
        () => WindowGeometry.fromMap(const {
          'x': 0.0,
          'y': 0.0,
          'width': 'wide',
          'height': 800.0,
          'maximized': false,
        }),
        throwsFormatException,
      );
    });

    test('rejects a non-positive width', () {
      // A zero-size window cannot be restored into and cannot be dragged back
      // to a usable size. Treat it as corrupt rather than obeying it.
      expect(
        () => WindowGeometry.fromMap(const {
          'x': 0.0,
          'y': 0.0,
          'width': 0.0,
          'height': 800.0,
          'maximized': false,
        }),
        throwsFormatException,
      );
    });

    test('rejects a negative height', () {
      expect(
        () => WindowGeometry.fromMap(const {
          'x': 0.0,
          'y': 0.0,
          'width': 1280.0,
          'height': -800.0,
          'maximized': false,
        }),
        throwsFormatException,
      );
    });

    test('reads integer numbers as doubles', () {
      // Hive round-trips whole doubles as ints in some encodings, so the
      // reader must not assume the exact numeric type it wrote.
      final restored = WindowGeometry.fromMap(const {
        'x': 0,
        'y': 0,
        'width': 1280,
        'height': 800,
        'maximized': false,
      });

      expect(restored.bounds, const Rect.fromLTWH(0, 0, 1280, 800));
    });

    test('copyWith replaces only what it is given', () {
      const original = WindowGeometry(
        bounds: Rect.fromLTWH(0, 0, 1280, 800),
        maximized: false,
      );

      final updated = original.copyWith(maximized: true);

      expect(updated.bounds, original.bounds);
      expect(updated.maximized, isTrue);
    });
  });
}
