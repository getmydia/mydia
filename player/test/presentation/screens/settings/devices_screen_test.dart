import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/domain/models/remote_device.dart';
import 'package:player/presentation/screens/settings/devices_screen.dart';

Future<void> _pumpCard(WidgetTester tester, RemoteDevice device) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: DeviceCard(device: device, onRevoke: () {}),
      ),
    ),
  );
  await tester.pump();
}

RemoteDevice _device({bool revoked = false}) => RemoteDevice(
      id: 'd-1',
      deviceName: 'Living room TV',
      platform: 'android',
      lastSeenAt: DateTime.utc(2026, 8, 1),
      isRevoked: revoked,
      createdAt: DateTime.utc(2026, 7, 1),
    );

void main() {
  testWidgets('an active device card uses the shared surface tone',
      (tester) async {
    await _pumpCard(tester, _device());

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(DeviceCard),
            matching: find.byType(Material),
          )
          .first,
    );

    expect(material.color, DepthTokens.surfaceVariant);
  });

  testWidgets('the device name renders', (tester) async {
    await _pumpCard(tester, _device());

    expect(find.text('Living room TV'), findsOneWidget);
    expect(find.text('Android'), findsOneWidget);
  });

  testWidgets('a revoked device shows the revoked badge and hides revoke',
      (tester) async {
    await _pumpCard(tester, _device(revoked: true));

    expect(find.text('Revoked'), findsOneWidget);
    expect(find.text('Revoke Device'), findsNothing);
  });

  testWidgets('the success colour still comes from AppColors', (tester) async {
    // ColorScheme has no success slot, so this one reference is expected to
    // stay on AppColors. Guards against a future sweep "fixing" it.
    expect(AppColors.success, const Color(0xFF12C68B));
  });
}
