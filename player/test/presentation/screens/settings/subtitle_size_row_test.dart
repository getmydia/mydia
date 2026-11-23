import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/subtitle_size.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/settings/subtitle_size_setting.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/settings/widgets/subtitle_size_row.dart';
import 'package:player/presentation/widgets/controls/app_segmented.dart';

import '../../../test_utils/mock_auth_storage.dart';

Widget _host(MockAuthStorage storage) => ProviderScope(
  overrides: [
    coreSettingsServiceProvider.overrideWithValue(
      SettingsService(storage: storage),
    ),
  ],
  child: const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SubtitleSizeSettingsRow()),
  ),
);

Finder _inRow(Finder matching) => find.descendant(
  of: find.byKey(const Key('subtitle-size-row')),
  matching: matching,
);

void main() {
  testWidgets('shows S M L XL with Medium selected by default', (tester) async {
    await tester.pumpWidget(_host(MockAuthStorage()));
    await tester.pumpAndSettle();

    for (final label in ['S', 'M', 'L', 'XL']) {
      expect(_inRow(find.text(label)), findsOneWidget, reason: label);
    }
    final control = tester.widget<AppSegmented<SubtitleSize>>(
      _inRow(find.byType(AppSegmented<SubtitleSize>)),
    );
    expect(control.selected, SubtitleSize.medium);
  });

  testWidgets('subtitle size row shows S M L XL and saves on change', (
    tester,
  ) async {
    final storage = MockAuthStorage();
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();

    await tester.tap(_inRow(find.byKey(AppSegmented.segmentKey(2))));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(storage.contents['subtitle_size'], 'large');
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('subtitle-size-row'))),
    );
    expect(
      container.read(subtitleSizeSettingProvider).value,
      SubtitleSize.large,
    );
    final control = tester.widget<AppSegmented<SubtitleSize>>(
      _inRow(find.byType(AppSegmented<SubtitleSize>)),
    );
    expect(control.selected, SubtitleSize.large);
  });

  testWidgets('the control is the row\'s one focus stop; Right saves', (
    tester,
  ) async {
    final storage = MockAuthStorage();
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final first = FocusManager.instance.primaryFocus;
    expect(
      find
          .descendant(
            of: find.byType(AppSegmented<SubtitleSize>),
            matching: find.byElementPredicate((e) => e == first?.context),
          )
          .evaluate(),
      isNotEmpty,
      reason: 'the first stop is the segmented control, not the row',
    );

    // Nothing else in the row is a traversal stop.
    final rowElement = tester.element(
      find.byKey(const Key('subtitle-size-row')),
    );
    final stopsInRow = FocusManager.instance.rootScope.traversalDescendants
        .where((node) {
          var inside = false;
          node.context?.visitAncestorElements((e) {
            inside = e == rowElement;
            return !inside;
          });
          return inside;
        });
    expect(stopsInRow, [same(first)]);

    first?.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(storage.contents['subtitle_size'], 'large');
  });
}
