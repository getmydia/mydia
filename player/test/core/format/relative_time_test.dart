import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/format/relative_time.dart';

void main() {
  final now = DateTime(2026, 7, 28, 12, 0);

  test('under a minute reads as just now', () {
    expect(
      formatRelativeTime(now.subtract(const Duration(seconds: 30)), now: now),
      'Just now',
    );
  });

  test('minutes are singular at one and plural above', () {
    expect(
      formatRelativeTime(now.subtract(const Duration(minutes: 1)), now: now),
      '1 minute ago',
    );
    expect(
      formatRelativeTime(now.subtract(const Duration(minutes: 42)), now: now),
      '42 minutes ago',
    );
  });

  test('hours, days, months and years each get their own unit', () {
    expect(
      formatRelativeTime(now.subtract(const Duration(hours: 3)), now: now),
      '3 hours ago',
    );
    expect(
      formatRelativeTime(now.subtract(const Duration(days: 2)), now: now),
      '2 days ago',
    );
    expect(
      formatRelativeTime(now.subtract(const Duration(days: 90)), now: now),
      '3 months ago',
    );
    expect(
      formatRelativeTime(now.subtract(const Duration(days: 800)), now: now),
      '2 years ago',
    );
  });

  test('a future timestamp is clamped to just now rather than reading negative',
      () {
    expect(
      formatRelativeTime(now.add(const Duration(minutes: 5)), now: now),
      'Just now',
    );
  });
}
