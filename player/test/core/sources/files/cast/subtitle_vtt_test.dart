import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/cast/subtitle_vtt.dart';

void main() {
  test('converts SRT cues and timestamps to WebVTT', () {
    const srt = '1\r\n'
        '00:00:01,050 --> 00:00:04,200\r\n'
        'Welcome to Copper Valley.\r\n'
        '\r\n'
        '2\r\n'
        '00:01:12,000 --> 00:01:15,500 line:90%\r\n'
        '<i>Morning</i> by the river.\r\n';

    final vtt = toWebVtt(srt, format: 'srt');
    expect(
      vtt,
      'WEBVTT\n\n'
      '1\n'
      '00:00:01.050 --> 00:00:04.200\n'
      'Welcome to Copper Valley.\n\n'
      '2\n'
      '00:01:12.000 --> 00:01:15.500 line:90%\n'
      '<i>Morning</i> by the river.\n',
    );
  });

  test('strips UTF-8 BOM from SRT and does not touch commas in dialogue', () {
    const srt = '\uFEFF1\n'
        '00:00:05,000 --> 00:00:08,125\n'
        'Wait, wait, wait --> 00:00:09,000 is not a timing line.\n';

    final vtt = toWebVtt(srt, format: 'srt');
    expect(vtt, startsWith('WEBVTT\n\n1\n00:00:05.000 --> 00:00:08.125\n'));
    expect(
      vtt,
      contains('Wait, wait, wait --> 00:00:09,000 is not a timing line.'),
    );
  });

  test('normalizes existing WebVTT and ensures WEBVTT header', () {
    const rawVtt = '\uFEFFWEBVTT - Harbor Lights\r\n\r\n'
        '00:00:01.000 --> 00:00:02.000\r\n'
        'Hello.\r\n';
    expect(
      toWebVtt(rawVtt, format: 'vtt'),
      'WEBVTT - Harbor Lights\n\n'
      '00:00:01.000 --> 00:00:02.000\n'
      'Hello.\n',
    );

    const headerlessVtt = '00:00:01.000 --> 00:00:02.000\nHello.';
    expect(
      toWebVtt(headerlessVtt, format: 'vtt'),
      'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello.\n',
    );
  });

  test('returns WEBVTT header for empty or whitespace-only input', () {
    expect(toWebVtt('', format: 'srt'), 'WEBVTT\n');
    expect(toWebVtt('   \r\n\t  ', format: 'srt'), 'WEBVTT\n');
    expect(toWebVtt('', format: 'vtt'), 'WEBVTT\n');
    expect(toWebVtt('   \n  ', format: 'vtt'), 'WEBVTT\n');
  });
}
