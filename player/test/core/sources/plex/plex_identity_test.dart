import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/plex/plex_identity.dart';

import '../../../test_utils/mock_auth_storage.dart';

void main() {
  test('creates the client identifier once and keeps it', () async {
    final storage = MockAuthStorage();
    final first = await PlexIdentity.loadClientIdentifier(storage);
    final second = await PlexIdentity.loadClientIdentifier(storage);
    expect(first, second);
    expect(first, matches(RegExp(r'^[a-f0-9]{32}$')));
  });

  test('sends the headers plex.tv requires', () {
    const identity = PlexIdentity(
      clientIdentifier: 'cid',
      version: '0.21.0',
      platform: 'Linux',
    );
    expect(identity.headers, {
      'X-Plex-Product': 'Mydia Player',
      'X-Plex-Version': '0.21.0',
      'X-Plex-Client-Identifier': 'cid',
      'X-Plex-Platform': 'Linux',
      'X-Plex-Device-Name': 'Mydia Player',
      'Accept': 'application/json',
    });
    expect(PlexIdentity.platformName(TargetPlatform.android), 'Android');
  });
}
