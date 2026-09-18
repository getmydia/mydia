import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/update_track.dart';
import 'package:player/presentation/screens/settings/widgets/track_picker_row.dart';

void main() {
  Widget host(Widget child) => ProviderScope(
        child: MaterialApp(home: Scaffold(body: child)),
      );

  testWidgets('renders one option per available track', (tester) async {
    await tester.pumpWidget(host(TrackPickerRow(
      availableTracks: const {UpdateTrack.stable, UpdateTrack.beta},
      currentTrack: UpdateTrack.stable,
      installedVersion: '0.15.0',
      onSelected: (_) async {},
    )));

    expect(find.byKey(const Key('update-track-option-stable')), findsOneWidget);
    expect(find.byKey(const Key('update-track-option-beta')), findsOneWidget);
    expect(find.byKey(const Key('update-track-option-dev')), findsNothing);
  });

  testWidgets('choosing a track reports it', (tester) async {
    UpdateTrack? chosen;
    await tester.pumpWidget(host(TrackPickerRow(
      availableTracks: const {UpdateTrack.stable, UpdateTrack.beta},
      currentTrack: UpdateTrack.stable,
      installedVersion: '0.15.0',
      onSelected: (track) async => chosen = track,
    )));

    await tester.tap(find.byKey(const Key('update-track-option-beta')));
    await tester.pumpAndSettle();

    expect(chosen, UpdateTrack.beta);
  });

  testWidgets('explains the wait when the running build is ahead',
      (tester) async {
    await tester.pumpWidget(host(TrackPickerRow(
      availableTracks: const {UpdateTrack.stable, UpdateTrack.dev},
      currentTrack: UpdateTrack.stable,
      installedVersion: '0.16.0-dev.7',
      onSelected: (_) async {},
    )));

    expect(
      find.textContaining('until', findRichText: true),
      findsWidgets,
    );
  });

  testWidgets('shows deferred instructions when the platform hands off',
      (tester) async {
    await tester.pumpWidget(host(TrackPickerRow(
      availableTracks: const {UpdateTrack.stable, UpdateTrack.beta},
      currentTrack: UpdateTrack.stable,
      installedVersion: '0.15.0',
      deferredInstructions: 'flatpak install mydia-beta dev.mydia.player//beta',
      onSelected: (_) async {},
    )));

    expect(find.textContaining('flatpak install'), findsOneWidget);
  });

  testWidgets('shows the link when the backend supplies one', (tester) async {
    const url =
        'https://docs.mydia.dev/latest/using/how-to/install-player-linux/';
    await tester.pumpWidget(host(TrackPickerRow(
      availableTracks: const {UpdateTrack.stable, UpdateTrack.beta},
      currentTrack: UpdateTrack.stable,
      installedVersion: '0.15.0',
      deferredInstructions: 'flatpak install mydia-beta dev.mydia.player//beta',
      deferredUrl: url,
      onSelected: (_) async {},
    )));

    expect(find.text(url), findsOneWidget);
  });

  testWidgets('shows no link when the backend gives none', (tester) async {
    await tester.pumpWidget(host(TrackPickerRow(
      availableTracks: const {UpdateTrack.stable, UpdateTrack.beta},
      currentTrack: UpdateTrack.stable,
      installedVersion: '0.15.0',
      deferredInstructions: 'flatpak install mydia-beta dev.mydia.player//beta',
      onSelected: (_) async {},
    )));

    expect(
      find.textContaining('https://', findRichText: true),
      findsNothing,
    );
  });

  testWidgets('marks the current track selected, and only that one',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(TrackPickerRow(
      availableTracks: const {UpdateTrack.stable, UpdateTrack.beta},
      currentTrack: UpdateTrack.beta,
      installedVersion: '0.15.0',
      onSelected: (_) async {},
    )));

    expect(
      tester.getSemantics(find.byKey(const Key('update-track-option-beta'))),
      matchesSemantics(
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('update-track-option-stable'))),
      matchesSemantics(
        isButton: true,
        isSelected: false,
        hasSelectedState: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );

    handle.dispose();
  });
}
