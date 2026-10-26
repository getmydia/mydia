import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/presentation/screens/filter/filter_editor_sheet.dart';

Future<BuildContext> _pump(WidgetTester tester, {required bool liquid}) async {
  late BuildContext captured;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.build(Palettes.projectionBooth, liquid: liquid),
        home: Scaffold(
          body: Builder(builder: (context) {
            captured = context;
            return FilterEditorSheet(
              initialFilter: MediaFilter.allMovies,
              editing: null,
              onSave: (_) async {},
            );
          }),
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets('on Liquid Glass the sheet surface is transparent so glass shows',
      (tester) async {
    await _pump(tester, liquid: true);
    final surface =
        tester.widget<Material>(find.byKey(const Key('filter-editor-surface')));
    expect(surface.color, Colors.transparent);
    expect(surface.borderRadius, isNull);
  });

  testWidgets('elsewhere the surface is palette.surface', (tester) async {
    final context = await _pump(tester, liquid: false);
    final surface =
        tester.widget<Material>(find.byKey(const Key('filter-editor-surface')));
    expect(surface.color, context.palette.surface);
  });
}
