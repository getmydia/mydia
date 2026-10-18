import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/presentation/screens/filter/filter_editor_sheet.dart';

Future<BuildContext> _pump(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
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
  tearDown(() => LiquidGlassSupport.debugPlatformOverride = null);

  testWidgets('on Apple the sheet surface is transparent so glass shows',
      (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    await _pump(tester);
    final surface =
        tester.widget<Material>(find.byKey(const Key('filter-editor-surface')));
    expect(surface.color, Colors.transparent);
    expect(surface.borderRadius, isNull);
  });

  testWidgets('elsewhere the surface is palette.surface', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = false;
    final context = await _pump(tester);
    final surface =
        tester.widget<Material>(find.byKey(const Key('filter-editor-surface')));
    expect(surface.color, context.palette.surface);
  });
}
