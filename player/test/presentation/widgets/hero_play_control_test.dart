import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/presentation/widgets/hero_play_control.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/presentation/widgets/primary_play_button.dart';

const _files = [
  MediaFile(id: 'f1', resolution: '1080p', directPlaySupported: true),
];

const _twoFiles = [
  MediaFile(id: 'f1', resolution: '1080p', directPlaySupported: true),
  MediaFile(id: 'f2', resolution: '720p', directPlaySupported: true),
];

/// Mirrors how both detail heroes embed the control: a Row whose leading child
/// is Expanded (the title column) and whose trailing child is non-flex.
Widget _host(Widget control) => MaterialApp(
      home: Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Expanded(child: Text('Some Title')),
            const SizedBox(width: 16),
            control,
          ],
        ),
      ),
    );

void main() {
  testWidgets('renders the Play label beside a play button', (tester) async {
    await tester.pumpWidget(_host(
      HeroPlayControl(files: _files, onFileSelected: (_) {}),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Play'), findsOneWidget);
    expect(find.byType(PrimaryPlayButton), findsOneWidget);
  });

  testWidgets('is the white primary button, not gold', (tester) async {
    await tester.pumpWidget(_host(
      HeroPlayControl(files: _files, onFileSelected: (_) {}),
    ));
    await tester.pumpAndSettle();

    final material = tester.widget<Material>(find.descendant(
      of: find.byType(PrimaryPlayButton),
      matching: find.byType(Material),
    ));
    expect(material.color, Colors.white);
    expect(
      material.borderRadius,
      const BorderRadius.all(Radius.circular(AppTheme.radiusButton)),
    );
    final label = tester.widget<Text>(find.text('Play'));
    expect(label.style?.color, AppColors.background);
    expect(label.style?.fontFamily, AppTheme.displayFamily);
    final icon = tester.widget<Icon>(find.byIcon(Icons.play_arrow_rounded));
    expect(icon.color, AppColors.background);
    // The version label stays beside the button, muted.
    expect(find.text('1080p'), findsOneWidget);
  });

  testWidgets('the icon-only button still announces itself as Play',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(
      PrimaryPlayButton(onPressed: () {}, iconOnly: true),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Play'), findsNothing);
    expect(find.bySemanticsLabel('Play'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('resume labels the button Resume', (tester) async {
    await tester.pumpWidget(_host(
      HeroPlayControl(files: _files, onFileSelected: (_) {}, resume: true),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Play'), findsNothing);
  });

  testWidgets('a button with nothing to play is disabled, not white',
      (tester) async {
    await tester.pumpWidget(_host(
      HeroPlayControl(files: const [], onFileSelected: (_) {}),
    ));
    await tester.pumpAndSettle();

    final material = tester.widget<Material>(find.descendant(
      of: find.byType(PrimaryPlayButton),
      matching: find.byType(Material),
    ));
    expect(material.color, AppColors.surfaceVariant);
  });

  testWidgets('tapping reports the auto-selected file', (tester) async {
    MediaFile? picked;
    await tester.pumpWidget(_host(
      HeroPlayControl(files: _files, onFileSelected: (f) => picked = f),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PrimaryPlayButton));
    await tester.pumpAndSettle();

    expect(picked?.id, 'f1');
  });

  testWidgets('as a non-flex trailing Row child it sits flush right',
      (tester) async {
    // This is the property the whole placement fix rests on: a non-flex Row
    // child takes its intrinsic width, so Expanded absorbs the slack and the
    // control lands against the parent's right edge. Asserted against the
    // host's own right edge rather than a hard-coded surface width, so this
    // expresses "flush with the host" instead of a coordinate that merely
    // happens to match it.
    await tester.pumpWidget(_host(
      HeroPlayControl(files: _files, onFileSelected: (_) {}),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byType(HeroPlayControl)).right,
      closeTo(tester.getRect(find.byType(Scaffold)).right, 0.5),
    );
  });

  testWidgets('stays flush right when a quality dropdown is present (2+ files)',
      (tester) async {
    // With 2+ files, SmartPlayButton renders a quality dropdown that becomes
    // the rightmost child instead of PrimaryPlayButton, so this asserts on
    // the control's own edge rather than the button's, as the two are not
    // interchangeable once the dropdown exists.
    await tester.pumpWidget(_host(
      HeroPlayControl(files: _twoFiles, onFileSelected: (_) {}),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byType(HeroPlayControl)).right,
      closeTo(tester.getRect(find.byType(Scaffold)).right, 0.5),
    );
  });
}
