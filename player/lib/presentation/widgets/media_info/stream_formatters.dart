// Formatting helpers for the Media Info panel.
//
// The server sends raw ffprobe values; composing them into display strings
// happens here. Deliberately free of Flutter imports so every function is
// unit-testable without pumping a widget.

/// Human readable file size, e.g. "54.2 GB".
String? formatBytes(int? bytes) {
  if (bytes == null) return null;
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final decimals = unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(decimals)} ${units[unit]}';
}

/// Human readable bitrate, e.g. "38.1 Mbps" or "768 kbps".
String? formatBitrate(int? bitsPerSecond) {
  if (bitsPerSecond == null) return null;
  if (bitsPerSecond >= 1000000) {
    return '${(bitsPerSecond / 1000000).toStringAsFixed(1)} Mbps';
  }
  return '${(bitsPerSecond / 1000).round()} kbps';
}

/// Duration as "2h 43m", or "42m" when under an hour.
String? formatDuration(double? seconds) {
  if (seconds == null) return null;
  final total = seconds.round();
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  if (hours == 0) return '${minutes}m';
  return '${hours}h ${minutes}m';
}

/// Frame rate with trailing zeros trimmed, e.g. "23.976 fps" or "24 fps".
String? formatFrameRate(double? fps) {
  if (fps == null) return null;
  var text = fps.toStringAsFixed(3);
  if (text.contains('.')) {
    text = text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return '$text fps';
}

/// Sample rate in kilohertz, e.g. "48 kHz".
String? formatSampleRate(int? hertz) {
  if (hertz == null) return null;
  final khz = hertz / 1000;
  final text = khz == khz.roundToDouble()
      ? khz.round().toString()
      : khz.toStringAsFixed(1);
  return '$text kHz';
}

/// Channel layout with its count, e.g. "7.1 (8 ch)".
String? formatChannels(int? channels, String? layout) {
  if (layout != null && layout.isNotEmpty && channels != null) {
    return '$layout ($channels ch)';
  }
  if (layout != null && layout.isNotEmpty) return layout;
  if (channels != null) return '$channels ch';
  return null;
}

const Map<String, String> _languageNames = {
  'eng': 'English',
  'en': 'English',
  'spa': 'Spanish',
  'es': 'Spanish',
  'fre': 'French',
  'fra': 'French',
  'fr': 'French',
  'ger': 'German',
  'deu': 'German',
  'de': 'German',
  'ita': 'Italian',
  'it': 'Italian',
  'por': 'Portuguese',
  'pt': 'Portuguese',
  'rus': 'Russian',
  'ru': 'Russian',
  'jpn': 'Japanese',
  'ja': 'Japanese',
  'kor': 'Korean',
  'ko': 'Korean',
  'chi': 'Chinese',
  'zho': 'Chinese',
  'zh': 'Chinese',
  'ara': 'Arabic',
  'ar': 'Arabic',
  'hin': 'Hindi',
  'hi': 'Hindi',
  'nld': 'Dutch',
  'dut': 'Dutch',
  'nl': 'Dutch',
  'swe': 'Swedish',
  'sv': 'Swedish',
  'nor': 'Norwegian',
  'no': 'Norwegian',
  'dan': 'Danish',
  'da': 'Danish',
  'fin': 'Finnish',
  'fi': 'Finnish',
  'pol': 'Polish',
  'pl': 'Polish',
  'tur': 'Turkish',
  'tr': 'Turkish',
};

/// Display name for an ISO 639 code, falling back to the upper cased code.
String? languageName(String? code) {
  if (code == null || code.isEmpty) return null;
  return _languageNames[code.toLowerCase()] ?? code.toUpperCase();
}
