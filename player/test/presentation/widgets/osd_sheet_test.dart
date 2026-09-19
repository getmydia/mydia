import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/osd_sheet.dart';

Widget _host(ValueChanged<String?> onResult) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onResult(
              await showOsdBottomSheet<String>(
                context: context,
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).pop('picked'),
                  child: const Text('sheet body'),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('shows the builder on the OSD material with no shadow',
      (tester) async {
    await tester.pumpWidget(_host((_) {}));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final surface = tester.widget<GlassSurface>(
      find.ancestor(
        of: find.text('sheet body'),
        matching: find.byType(GlassSurface),
      ),
    );
    expect(surface.blurSigma, DepthTokens.osdBlurSigma);
    expect(surface.shadows, isEmpty);
    expect(
      surface.borderRadius,
      const BorderRadius.vertical(
        top: Radius.circular(DepthTokens.radiusOsdSheet),
      ),
    );
  });

  testWidgets('the sheet paints no Material of its own', (tester) async {
    await tester.pumpWidget(_host((_) {}));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.backgroundColor, Colors.transparent);
    expect(sheet.elevation, 0);
  });

  testWidgets('returns the popped value', (tester) async {
    String? result;
    await tester.pumpWidget(_host((value) => result = value));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('sheet body'));
    await tester.pumpAndSettle();

    expect(result, 'picked');
  });
}
