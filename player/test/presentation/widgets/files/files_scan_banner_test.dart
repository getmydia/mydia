import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/files_scan_controller.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/files/files_scan_banner.dart';

import '../../screens/sources/fake_media_source.dart';

class _FixedScan extends FilesScanController {
  _FixedScan(super.sourceId);

  @override
  ScanState build() => const ScanState(running: true, done: 312, total: 2040);

  void set(ScanState next) => state = next;
}

void main() {
  testWidgets('banner_follows_the_scan_and_hides_when_it_ends', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        filesScanProvider(fakeSourceId)
            .overrideWith(() => _FixedScan(fakeSourceId))
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: FilesScanBanner(sourceId: fakeSourceId)),
      ),
    ));
    expect(find.text('Scanning 312 of 2,040'), findsOneWidget);

    // The same banner, still mounted, follows the controller.
    final scan =
        ProviderScope.containerOf(tester.element(find.byType(FilesScanBanner)))
            .read(filesScanProvider(fakeSourceId).notifier) as _FixedScan;
    scan.set(const ScanState(running: true, done: 1500, total: 2040));
    await tester.pump();
    expect(find.text('Scanning 1,500 of 2,040'), findsOneWidget);

    scan.set(const ScanState(done: 2040, total: 2040));
    await tester.pump();
    expect(find.byKey(const Key('files-scan-banner')), findsNothing);
    expect(find.textContaining('Scanning'), findsNothing);
    expect(find.byKey(const Key('files-scan-skipped')), findsNothing);

    // A finished scan that left folders out says so.
    scan.set(const ScanState(done: 2040, total: 2040, skippedFolders: 1));
    await tester.pump();
    expect(find.text('1 folder skipped: it could not be read'), findsOneWidget);

    scan.set(const ScanState(done: 2040, total: 2040, skippedFolders: 3));
    await tester.pump();
    expect(
        find.text('3 folders skipped: they could not be read'), findsOneWidget);

    // The next scan's progress replaces it.
    scan.set(const ScanState(
        running: true, done: 1, total: 2040, skippedFolders: 3));
    await tester.pump();
    expect(find.text('Scanning 1 of 2,040'), findsOneWidget);
    expect(find.byKey(const Key('files-scan-skipped')), findsNothing);
  });
}
