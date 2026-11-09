final _srtTimingLine = RegExp(
  r'^(\d{1,2}:\d{2}:\d{2})[,.](\d{3})(\s*-->\s*)(\d{1,2}:\d{2}:\d{2})[,.](\d{3})(.*)$',
);

/// Converts a `.srt` or `.vtt` subtitle payload into a valid UTF-8 WebVTT
/// document suitable for Chromecast `<track>` elements.
String toWebVtt(String raw, {required String format}) {
  var text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();

  if (text.isEmpty) return 'WEBVTT\n';

  if (format.trim().toLowerCase() == 'vtt') {
    if (text.startsWith('WEBVTT')) {
      return '$text\n';
    }
    return 'WEBVTT\n\n$text\n';
  }

  final lines = text.split('\n');
  final buffer = StringBuffer('WEBVTT\n\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final match = _srtTimingLine.firstMatch(line);
    if (match != null) {
      buffer
        ..write(match.group(1))
        ..write('.')
        ..write(match.group(2))
        ..write(match.group(3))
        ..write(match.group(4))
        ..write('.')
        ..write(match.group(5))
        ..writeln(match.group(6));
    } else {
      buffer.writeln(line);
    }
  }
  return buffer.toString();
}
