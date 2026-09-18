import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/settings/stats_overlay_setting.dart';
import 'package:player/presentation/screens/settings/widgets/settings_row.dart';

import '../../../test_utils/mock_auth_storage.dart';

const statsRowKey = Key('stats-overlay-switch');

void main() {
  testWidgets('the row reads the flag and writes it back', (tester) async {
    final storage = MockAuthStorage();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreSettingsServiceProvider
              .overrideWithValue(SettingsService(storage: storage)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final enabled =
                    ref.watch(statsOverlayEnabledProvider).value ?? false;
                return SettingsRow.toggle(
                  key: statsRowKey,
                  icon: Icons.speed,
                  title: 'Stats for nerds',
                  subtitle: 'Live playback numbers over the video',
                  value: enabled,
                  onChanged: (value) =>
                      ref.read(statsOverlayEnabledProvider.notifier).set(value),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(storage.contents['stats_overlay_enabled'], 'true');
  });
}
