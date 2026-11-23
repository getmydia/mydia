import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/theme_preset.dart';
import 'package:player/core/theme/theme_providers.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/settings/widgets/theme_preset_row.dart';

import '../../../test_utils/mock_auth_storage.dart';

class _ThemedHost extends ConsumerWidget {
  const _ThemedHost();
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: AppTheme.build(ref.watch(paletteProvider), liquid: false),
    home: const Scaffold(body: ThemePresetSettingsRow()),
  );
}

Widget _host(MockAuthStorage storage) => ProviderScope(
  overrides: [
    coreSettingsServiceProvider.overrideWithValue(
      SettingsService(storage: storage),
    ),
  ],
  child: const _ThemedHost(),
);

Finder _choice(int i) => find.byKey(Key('settings-choice-$i'));

void main() {
  testWidgets('offers one card per preset available on this platform', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(_host(MockAuthStorage()));
      await tester.pumpAndSettle();
      final count = ThemePreset.availableOn(TargetPlatform.android).length;
      expect(_choice(count - 1), findsOneWidget);
      expect(_choice(count), findsNothing);
      expect(find.text('Colours on this device'), findsOneWidget);
      expect(find.text('Projection Booth'), findsOneWidget);
      expect(find.text('OLED Black'), findsOneWidget);
      expect(find.text('macOS'), findsNothing);

      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(MockAuthStorage()));
      await tester.pumpAndSettle();
      expect(find.text('macOS'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('picking a preset stores it and re-themes the app', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final storage = MockAuthStorage();
      await tester.pumpWidget(_host(storage));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OLED Black'));
      await tester.pumpAndSettle();

      expect(storage.contents['theme_preset'], 'oledBlack');
      final context = tester.element(find.byKey(const Key('theme-preset-row')));
      expect(Theme.of(context).extension<MydiaPalette>(), Palettes.oledBlack);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
