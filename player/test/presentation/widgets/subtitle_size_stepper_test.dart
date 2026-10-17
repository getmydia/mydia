import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/presentation/widgets/subtitle_size_stepper.dart';

import '../../test_utils/mock_auth_storage.dart';

const _dec = Key('subtitle-size-decrement');
const _inc = Key('subtitle-size-increment');
const _value = Key('subtitle-size-value');

Widget _host(MockAuthStorage storage) => ProviderScope(
      overrides: [
        coreSettingsServiceProvider
            .overrideWithValue(SettingsService(storage: storage)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SubtitleSizeStepper()),
      ),
    );

String _label(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(_value)).data!;

void main() {
  testWidgets('starts at Medium and steps up, storing each step',
      (tester) async {
    final storage = MockAuthStorage();
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();
    expect(_label(tester), 'Medium');

    await tester.tap(find.byKey(_inc));
    await tester.pumpAndSettle();
    expect(_label(tester), 'Large');
    expect(storage.contents['subtitle_size'], 'large');

    await tester.tap(find.byKey(_inc));
    await tester.pumpAndSettle();
    expect(_label(tester), 'Extra large');
    expect(
      tester.widget<IconButton>(find.byKey(_inc)).onPressed,
      isNull,
      reason: 'no step past the largest preset',
    );
  });

  testWidgets('disables decrement at Small', (tester) async {
    final storage = MockAuthStorage();
    await storage.write('subtitle_size', 'small');
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();

    expect(_label(tester), 'Small');
    expect(tester.widget<IconButton>(find.byKey(_dec)).onPressed, isNull);
  });
}
