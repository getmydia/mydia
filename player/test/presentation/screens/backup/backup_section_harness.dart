import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_providers.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/backup/google_device_code_sheet.dart';
import 'package:player/presentation/screens/connections/backup_section.dart';

import '../../../test_utils/toast_harness.dart';
import 'fake_backup_controller.dart';

/// Pumps Backup & sync over [controller], signing in to Google with
/// [google] (none when null).
Future<void> pumpBackupSection(
  WidgetTester tester,
  FakeBackupController controller, {
  FakeGoogleSignIn? google,
}) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backupSyncServiceProvider.overrideWithValue(controller.relay),
        backupControllerProvider.overrideWithValue(controller),
        googleSignInMethodProvider.overrideWithValue(google?.method),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: toastLayerBuilder,
        home: Scaffold(body: SingleChildScrollView(child: BackupSection())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
