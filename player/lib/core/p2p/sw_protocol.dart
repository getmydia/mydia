/// Wire format between the Service Worker and the page.
///
/// The worker cannot reach the p2p connection itself, so it forwards each
/// intercepted request here and streams the reply back over a MessageChannel.
/// See player/web/sw.js for the other half.
class SwRequest {
  final String id;
  final String path;
  final int? rangeStart;
  final int? rangeEnd;

  const SwRequest({
    required this.id,
    required this.path,
    this.rangeStart,
    this.rangeEnd,
  });

  factory SwRequest.fromMessage(Map<String, dynamic> message) {
    final headers = (message['headers'] as Map?)?.cast<String, String>() ?? {};
    final range = _parseRange(headers['range'] ?? headers['Range']);

    return SwRequest(
      id: message['id'] as String,
      path: message['path'] as String,
      rangeStart: range?.$1,
      rangeEnd: range?.$2,
    );
  }

  /// Parses `bytes=<start>-<end>`. The end is optional, as in `bytes=2048-`.
  static (int, int?)? _parseRange(String? header) {
    if (header == null || !header.startsWith('bytes=')) return null;
    final parts = header.substring('bytes='.length).split('-');
    if (parts.isEmpty) return null;
    final start = int.tryParse(parts[0]);
    if (start == null) return null;
    final end = parts.length > 1 ? int.tryParse(parts[1]) : null;
    return (start, end);
  }
}
