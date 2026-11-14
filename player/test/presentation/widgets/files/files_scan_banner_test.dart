import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/files_scan_controller.dart';
import 'package:player/core/sources/files/media_info/files_probe_queue.dart';
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

    // A finished scan that left folders or files out says so.
    scan.set(const ScanState(done: 2040, total: 2040, skippedCount: 1));
    await tester.pump();
    expect(find.text('1 item skipped: it could not be read'), findsOneWidget);

    scan.set(const ScanState(done: 2040, total: 2040, skippedCount: 3));
    await tester.pump();
    expect(
        find.text('3 items skipped: they could not be read'), findsOneWidget);

    // The next scan's progress replaces it.
    scan.set(
        const ScanState(running: true, done: 1, total: 2040, skippedCount: 3));
    await tester.pump();
    expect(find.text('Scanning 1 of 2,040'), findsOneWidget);
    expect(find.byKey(const Key('files-scan-skipped')), findsNothing);

    // While the folders are still being read there is no total yet: the
    // banner counts folders instead of showing "0 of 0".
    scan.set(const ScanState(running: true, walking: true, foldersRead: 1204));
    await tester.pump();
    expect(find.text('Reading folders: 1,204'), findsOneWidget);
    expect(find.textContaining('of 0'), findsNothing);
  });

  testWidgets('shows Reading file details while probing after a scan',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        filesScanProvider(fakeSourceId)
            .overrideWith(() => _IdleScan(fakeSourceId)),
        filesProbeQueueProvider(fakeSourceId)
            .overrideWith(() => _FixedProbe(fakeSourceId)),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: FilesScanBanner(sourceId: fakeSourceId)),
      ),
    ));
    expect(find.byKey(const Key('files-probe-progress')), findsOneWidget);
    expect(find.text('Reading file details 3 of 10'), findsOneWidget);
    expect(find.byKey(const Key('files-scan-banner')), findsNothing);
  });

  test('an idle scan shows the banner only while probing', () {
    const idle = ScanState(done: 10, total: 10);
    expect(filesScanBannerShows(idle), isFalse);
    expect(
        filesScanBannerShows(idle,
            probe: const ProbeProgress(running: true, done: 1, total: 2)),
        isTrue);
    expect(
        filesScanBannerShows(idle,
            probe: const ProbeProgress(done: 2, total: 2)),
        isFalse);
  });
}

class _IdleScan extends FilesScanController {
  _IdleScan(super.sourceId);

  @override
  ScanState build() => const ScanState(done: 10, total: 10);
}

class _FixedProbe extends FilesProbeQueue {
  _FixedProbe(super.sourceId);

  @override
  ProbeProgress build() =>
      const ProbeProgress(running: true, done: 3, total: 10);
}
