import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/cast_subtitle_sheet.dart';

void main() {
  const tracks = [
    CastSubtitleTrack(
        trackId: '1', url: 'u1', label: 'English', language: 'eng'),
    CastSubtitleTrack(
        trackId: '2', url: 'u2', label: 'Spanish', language: 'spa'),
  ];

  Future<CastSubtitleSelection?> open(
    WidgetTester tester, {
    CastSubtitleTrack? selected,
  }) async {
    CastSubtitleSelection? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            result = await showCastSubtitleSheet(
              context,
              tracks: tracks,
              selected: selected,
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('lists Off plus every track', (tester) async {
    await open(tester);

    expect(find.byKey(const Key('cast-subtitle-off')), findsOneWidget);
    expect(find.byKey(const Key('cast-subtitle-track-1')), findsOneWidget);
    expect(find.byKey(const Key('cast-subtitle-track-2')), findsOneWidget);
  });

  testWidgets('picking a track returns that track', (tester) async {
    CastSubtitleSelection? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            picked = await showCastSubtitleSheet(
              context,
              tracks: tracks,
              selected: null,
            );
          },
          child: const Text('open'),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cast-subtitle-track-2')));
    await tester.pumpAndSettle();

    expect(picked, isA<CastSubtitlePicked>());
    expect((picked! as CastSubtitlePicked).track.trackId, '2');
  });

  testWidgets('the current track is the one showing a check', (tester) async {
    await open(tester, selected: tracks.last);

    final checked = find.descendant(
      of: find.byKey(const Key('cast-subtitle-track-2')),
      matching: find.byIcon(Icons.check),
    );
    expect(checked, findsOneWidget);

    final offChecked = find.descendant(
      of: find.byKey(const Key('cast-subtitle-off')),
      matching: find.byIcon(Icons.check),
    );
    expect(offChecked, findsNothing);
  });

  testWidgets('picking Off returns the Off outcome, distinct from a dismissal',
      (tester) async {
    CastSubtitleSelection? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            picked = await showCastSubtitleSheet(
              context,
              tracks: tracks,
              selected: tracks.first,
            );
          },
          child: const Text('open'),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cast-subtitle-off')));
    await tester.pumpAndSettle();

    expect(picked, isA<CastSubtitleOff>());
  });

  testWidgets('a barrier tap is a cancellation, not Off', (tester) async {
    CastSubtitleSelection? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            picked = await showCastSubtitleSheet(
              context,
              tracks: tracks,
              selected: tracks.first,
            );
          },
          child: const Text('open'),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // Distinguishing these two is the whole reason the result is a sealed
    // type rather than a nullable track: a dismissal must leave the receiver
    // alone, and turning subtitles off must not read as one.
    expect(picked, isA<CastSubtitleCancelled>());
  });
}
