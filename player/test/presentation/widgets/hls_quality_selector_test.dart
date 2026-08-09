import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/quality_delivery_subtitle.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/presentation/widgets/hls_quality_selector.dart';

Widget _host(void Function(BuildContext) onReady) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => onReady(context),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  final ladder = deriveQualityLadder(sourceHeight: 2160);

  testWidgets('lists every rung in the supplied ladder', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showQualityPicker(
          context,
          ladder,
          QualityRung.original,
          originalSubtitle: kOriginalDirectPlaySubtitle,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    for (final rung in ladder) {
      expect(find.text(rung.label), findsOneWidget);
    }
  });

  testWidgets('returns the tapped rung', (tester) async {
    QualityRung? result;
    await tester.pumpWidget(
      _host((context) async {
        result = await showQualityPicker(
          context,
          ladder,
          QualityRung.original,
          originalSubtitle: kOriginalDirectPlaySubtitle,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('720p'));
    await tester.pumpAndSettle();

    expect(result?.label, '720p');
    expect(result?.maxBitrateKbps, 4000);
  });

  testWidgets('returns null when dismissed', (tester) async {
    QualityRung? result;
    var completed = false;
    await tester.pumpWidget(
      _host((context) async {
        result = await showQualityPicker(
          context,
          ladder,
          QualityRung.original,
          originalSubtitle: kOriginalDirectPlaySubtitle,
        );
        completed = true;
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(result, isNull);
  });

  testWidgets('marks the current rung as selected', (tester) async {
    const current =
        QualityRung(label: '480p', height: 480, maxBitrateKbps: 1500);
    await tester.pumpWidget(
      _host(
        (context) => showQualityPicker(
          context,
          ladder,
          current,
          originalSubtitle: kOriginalDirectPlaySubtitle,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quality-rung-selected-480p')), findsOneWidget);
  });

  testWidgets('shows a clamp note when the server limited the stream',
      (tester) async {
    // A relay caps at 2000kbps and 720p regardless of what was asked for.
    // Saying so beats letting the viewer think their choice was applied.
    await tester.pumpWidget(
      _host((context) => showQualityPicker(
            context,
            ladder,
            QualityRung.original,
            originalSubtitle: kOriginalDirectPlaySubtitle,
            clampNote: 'Limited to 720p by your remote connection',
          )),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.text('Limited to 720p by your remote connection'),
      findsOneWidget,
    );
  });

  testWidgets('omits the note when nothing was clamped', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showQualityPicker(
          context,
          ladder,
          QualityRung.original,
          originalSubtitle: kOriginalDirectPlaySubtitle,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quality-clamp-note')), findsNothing);
  });

  testWidgets('shows the supplied Original delivery subtitle', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showQualityPicker(
          context,
          ladder,
          QualityRung.original,
          originalSubtitle: kOriginalTranscodeSubtitle,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(kOriginalTranscodeSubtitle), findsOneWidget);
    expect(find.text('Source quality, no re-encoding'), findsNothing);
  });

  testWidgets('shows Direct Play and lossless Original subtitles when supplied',
      (tester) async {
    for (final subtitle in [
      kOriginalDirectPlaySubtitle,
      kOriginalLosslessSubtitle,
    ]) {
      await tester.pumpWidget(
        _host(
          (context) => showQualityPicker(
            context,
            ladder,
            QualityRung.original,
            originalSubtitle: subtitle,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(subtitle), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('labels capped rungs as transcoding', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showQualityPicker(
          context,
          ladder,
          QualityRung.original,
          originalSubtitle: kOriginalDirectPlaySubtitle,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Transcodes · up to 4000 kbps'), findsOneWidget);
    expect(find.text('Up to 4000 kbps'), findsNothing);
  });
}
