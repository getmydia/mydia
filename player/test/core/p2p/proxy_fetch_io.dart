import 'dart:io';
import 'dart:typed_data';

/// GET [url] with a real HTTP client, so the loopback proxy is exercised
/// through a socket rather than by calling its handler directly.
Future<({int status, Uint8List body})> proxyGet(
  String url, {
  String? range,
}) async {
  final client = HttpClient();

  try {
    final request = await client.getUrl(Uri.parse(url));
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, range);
    }

    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (accumulated, chunk) => accumulated..addAll(chunk),
    );

    return (status: response.statusCode, body: Uint8List.fromList(bytes));
  } finally {
    client.close(force: true);
  }
}
