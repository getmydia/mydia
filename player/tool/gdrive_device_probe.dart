// Probe: does Google's device-code flow accept the `drive.appdata` scope?
//
// Usage (from player/): dart run tool/gdrive_device_probe.dart <client_id>
//
// The client id must belong to a "TVs and Limited Input devices" OAuth
// client. A 200 response with a `user_code` means the scope is allowed on
// the limited-input flow. An `invalid_scope` error means it is not.
import 'dart:convert';
import 'dart:io';

const _deviceCodeUrl = 'https://oauth2.googleapis.com/device/code';
const _scope = 'https://www.googleapis.com/auth/drive.appdata';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first.trim().isEmpty) {
    stderr.writeln(
      'usage: dart run tool/gdrive_device_probe.dart <client_id>',
    );
    exit(64);
  }

  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(_deviceCodeUrl));
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    request.write(
      Uri(
        queryParameters: {'client_id': args.first.trim(), 'scope': _scope},
      ).query,
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    stdout.writeln('HTTP ${response.statusCode}');
    stdout.writeln(body);
    exit(response.statusCode == 200 && body.contains('user_code') ? 0 : 1);
  } finally {
    client.close();
  }
}
