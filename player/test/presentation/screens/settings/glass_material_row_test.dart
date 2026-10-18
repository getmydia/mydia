import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/glass_material.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/theme_providers.dart';
import 'package:player/presentation/screens/settings/widgets/glass_material_row.dart';

import '../../../test_utils/mock_auth_storage.dart';

Widget _host(MockAuthStorage storage, {bool? isTv}) => ProviderScope(
      overrides: [
        coreSettingsServiceProvider
            .overrideWithValue(SettingsService(storage: storage)),
      ],
      child: MaterialApp(
        theme: AppTheme.build(Palettes.projectionBooth, liquid: false),
        home: Scaffold(body: GlassMaterialSettingsRow(debugIsTv: isTv)),
      ),
    );

void main() {
  testWidgets('toggling switches the material and persists it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final storage = MockAuthStorage();
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();
    final element = tester.element(find.byKey(const Key('glass-material-row')));
    final container = ProviderScope.containerOf(element);
    expect(container.read(glassMaterialSettingProvider), GlassMaterial.frosted);

    await tester.tap(find.descendant(
        of: find.byKey(const Key('glass-material-row')),
        matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    expect(container.read(glassMaterialSettingProvider), GlassMaterial.liquid);
    expect(storage.contents['glass_material'], 'liquid');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('is not shown on TV', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(_host(MockAuthStorage(), isTv: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('glass-material-row')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
