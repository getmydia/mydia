import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Locations are built in detail_links.dart, the router and the legacy
/// redirect table, nowhere else.
void main() {
  test(
    'no screen builds a detail, collection or player path itself',
    () {
      const allowed = {
        'lib/presentation/screens/detail/detail_links.dart',
        'lib/core/router/app_router.dart',
        'lib/core/router/legacy_routes.dart',
        'lib/core/router/source_detail_routes.dart',
        // Playback belongs to stage 3, which removes this entry.
        'lib/presentation/screens/player/session/mydia_playback_session.dart',
      };
      final pattern =
          RegExp(r"""['"]/(movie|show|episode|collection|player)/""");
      final offenders = [
        for (final f
            in Directory('lib').listSync(recursive: true).whereType<File>())
          if (f.path.endsWith('.dart') &&
              !f.path.endsWith('.g.dart') &&
              !allowed.contains(f.path) &&
              pattern.hasMatch(f.readAsStringSync()))
            f.path,
      ];
      expect(offenders, isEmpty);
    },
  );
}
