import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/glass_material.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/theme_providers.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/settings/widgets/glass_material_row.dart';

import '../../../test_utils/mock_auth_storage.dart';

Widget _host(MockAuthStorage storage, {bool? isTv}) => ProviderScope(
  overrides: [
    coreSettingsServiceProvider.overrideWithValue(
      SettingsService(storage: storage),
    ),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: AppTheme.build(Palettes.projectionBooth, liquid: false),
    home: Scaffold(body: GlassMaterialSettingsRow(debugIsTv: isTv)),
  ),
);

void main() {
  testWidgets('offers Liquid Glass and Frosted; picking one persists it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final storage = MockAuthStorage();
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();
    final element = tester.element(find.byKey(const Key('glass-material-row')));
    final container = ProviderScope.containerOf(element);
    expect(container.read(glassMaterialSettingProvider), GlassMaterial.frosted);
    expect(find.byKey(const Key('settings-choice-0')), findsOneWidget);
    expect(find.byKey(const Key('settings-choice-1')), findsOneWidget);
    expect(find.text('Liquid Glass'), findsOneWidget);
    expect(find.text('Frosted'), findsOneWidget);
    expect(find.text('Material'), findsOneWidget);

    await tester.tap(find.text('Liquid Glass'));
    await tester.pumpAndSettle();
    expect(container.read(glassMaterialSettingProvider), GlassMaterial.liquid);
    expect(storage.contents['glass_material'], 'liquid');

    await tester.tap(find.text('Frosted'));
    await tester.pumpAndSettle();
    expect(container.read(glassMaterialSettingProvider), GlassMaterial.frosted);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('announces the selected material as checked in a group', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(MockAuthStorage()));
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.byKey(const Key('settings-choice-1'))),
      isSemantics(
        label: 'Frosted',
        isInMutuallyExclusiveGroup: true,
        hasCheckedState: true,
        isChecked: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('settings-choice-0'))),
      isSemantics(
        label: 'Liquid Glass',
        isInMutuallyExclusiveGroup: true,
        hasCheckedState: true,
        isChecked: false,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    handle.dispose();
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
