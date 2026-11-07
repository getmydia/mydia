import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/files_scan_controller.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/files/files_scan_banner.dart';

import '../../screens/sources/fake_media_source.dart';

class _FixedScan extends FilesScanController {
  _FixedScan(super.sourceId);

  static ScanState next = const ScanState();

  @override
  ScanState build() => next;
}

Future<void> _pump(WidgetTester tester, ScanState state) async {
  _FixedScan.next = state;
  await tester.pumpWidget(ProviderScope(
    key: UniqueKey(),
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
}

void main() {
  testWidgets('banner_shows_grouped_counts_and_hides_when_idle',
      (tester) async {
    await _pump(tester, const ScanState(running: true, done: 312, total: 2040));
    expect(find.text('Scanning 312 of 2,040'), findsOneWidget);

    await _pump(tester, const ScanState(done: 2040, total: 2040));
    await tester.pump();
    expect(find.byKey(const Key('files-scan-banner')), findsNothing);
    expect(find.textContaining('Scanning'), findsNothing);
  });
}
