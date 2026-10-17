import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/theme_providers.dart';
import 'package:player/presentation/screens/settings/widgets/theme_preset_row.dart';

import '../../../test_utils/mock_auth_storage.dart';

class _ThemedHost extends ConsumerWidget {
  const _ThemedHost();
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
        theme: AppTheme.build(ref.watch(paletteProvider)),
        home: const Scaffold(body: ThemePresetSettingsRow()),
      );
}

Widget _host(MockAuthStorage storage) => ProviderScope(
      overrides: [
        coreSettingsServiceProvider
            .overrideWithValue(SettingsService(storage: storage)),
      ],
      child: const _ThemedHost(),
    );

void main() {
  testWidgets('shows the current preset', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(_host(MockAuthStorage()));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('theme-preset-row')),
        matching: find.text('Projection Booth'),
      ),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('offers macOS only on macOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(_host(MockAuthStorage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-preset-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('theme-preset-option-macos')), findsNothing);
    expect(
      find.byKey(const Key('theme-preset-option-oledBlack')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('theme-preset-option-oledBlack')));
    await tester.pumpAndSettle();

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(_host(MockAuthStorage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-preset-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('theme-preset-option-macos')), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('picking a preset stores it and re-themes the app',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final storage = MockAuthStorage();
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-preset-row')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-preset-option-oledBlack')));
    await tester.pumpAndSettle();

    expect(storage.contents['theme_preset'], 'oledBlack');
    final context = tester.element(find.byKey(const Key('theme-preset-row')));
    expect(Theme.of(context).extension<MydiaPalette>(), Palettes.oledBlack);
    expect(
      find.descendant(
        of: find.byKey(const Key('theme-preset-row')),
        matching: find.text('OLED Black'),
      ),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
