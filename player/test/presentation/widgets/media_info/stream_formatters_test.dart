import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/media_info/stream_formatters.dart';

void main() {
  group('formatBytes', () {
    test(
        'formats gigabytes', () => expect(formatBytes(58200000000), '54.2 GB'));
    test('formats megabytes', () => expect(formatBytes(8400000), '8.0 MB'));
    test('returns null for null', () => expect(formatBytes(null), isNull));
  });

  group('formatBitrate', () {
    test(
        'formats megabits', () => expect(formatBitrate(38100000), '38.1 Mbps'));
    test('formats kilobits', () => expect(formatBitrate(768000), '768 kbps'));
    test('returns null for null', () => expect(formatBitrate(null), isNull));
  });

  group('formatDuration', () {
    test('formats hours and minutes',
        () => expect(formatDuration(9780), '2h 43m'));
    test('formats minutes only', () => expect(formatDuration(2520), '42m'));
    test('returns null for null', () => expect(formatDuration(null), isNull));
  });

  group('formatFrameRate', () {
    test('trims trailing zeros', () => expect(formatFrameRate(24.0), '24 fps'));
    test('keeps fractional rates',
        () => expect(formatFrameRate(23.976), '23.976 fps'));
    test('returns null for null', () => expect(formatFrameRate(null), isNull));
  });

  group('formatSampleRate', () {
    test('formats kilohertz', () => expect(formatSampleRate(48000), '48 kHz'));
    test('returns null for null', () => expect(formatSampleRate(null), isNull));
  });

  group('formatChannels', () {
    test('combines layout and count',
        () => expect(formatChannels(8, '7.1'), '7.1 (8 ch)'));
    test('falls back to count alone',
        () => expect(formatChannels(2, null), '2 ch'));
    test('returns null when both are null',
        () => expect(formatChannels(null, null), isNull));
  });

  group('languageName', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final es = lookupAppLocalizations(const Locale('es'));

    test('maps three letter codes',
        () => expect(l10n.languageName('eng'), 'English'));
    test('maps two letter codes',
        () => expect(l10n.languageName('es'), 'Spanish'));
    test('names the language in the viewer\'s language',
        () => expect(es.languageName('eng'), 'Inglés'));
    test('upper cases unknown codes',
        () => expect(l10n.languageName('zzz'), 'ZZZ'));
    test(
        'returns null for null', () => expect(l10n.languageName(null), isNull));
  });
}
