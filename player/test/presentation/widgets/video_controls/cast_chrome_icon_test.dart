// The playback chrome's cast affordance.
//
// `CastButton` cannot be reused inside the top bar: it is a 48px `IconButton`
// carrying its own opaque black background, which neither fits `GlassPill`'s
// 36px height nor wants a second surface behind the one the pill already
// draws. `CastChromeIcon` renders the glyph alone and lets the pill own the
// surface, the tap target and the hover cursor.
//
// The two draw from different Material icon families on purpose — the chrome
// is `_rounded` throughout (see icon_family_test.dart), app bars are not — so
// the parity group below asserts they agree on *meaning* (connected-ness,
// colour, wording) rather than on identical `IconData`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is not re-exported by the main `flutter_riverpod.dart` barrel in
// Riverpod 3.x; it lives in the `misc.dart` sub-library.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/cast_button.dart';
import 'package:player/presentation/widgets/video_controls/cast_chrome_icon.dart';

const _device = CastDevice(
  id: 'device-1',
  name: 'Living Room TV',
  protocol: CastProtocolKind.chromecast,
);

void main() {
  Future<void> pumpIcon(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: overrides,
      child: const MaterialApp(
        home: Scaffold(
          // The pill's IconTheme, reproduced: an idle glyph must inherit this
          // rather than hard-coding a colour of its own.
          body: IconTheme(
            data: IconThemeData(size: 18, color: Color(0xCCFFFFFF)),
            child: CastChromeIcon(),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Icon iconOf(WidgetTester tester) =>
      tester.widget<Icon>(find.byKey(CastChromeIcon.iconKey));

  String? tooltipOf(WidgetTester tester) =>
      tester.widget<Tooltip>(find.byType(Tooltip)).message;

  group('CastChromeIcon', () {
    testWidgets(
        'idle inherits the chrome icon colour instead of forcing its own, so '
        'the cast glyph matches the back chevron beside it', (tester) async {
      await pumpIcon(tester);

      expect(iconOf(tester).icon, Icons.cast_rounded);
      expect(iconOf(tester).color, isNull,
          reason: 'a null colour is what makes Icon fall back to the '
              "surrounding IconTheme — CastButton's opaque white would read "
              'brighter than every other pill glyph');
      expect(tooltipOf(tester), 'Cast to device');
    });

    testWidgets('a live cast shows the connected glyph in blue',
        (tester) async {
      await pumpIcon(tester, overrides: [
        castConnectionProvider.overrideWithValue(CastConnection.casting),
        castDisplayDeviceProvider.overrideWithValue(_device),
      ]);

      expect(iconOf(tester).icon, Icons.cast_connected_rounded);
      expect(iconOf(tester).color, Colors.blue);
      expect(tooltipOf(tester), 'Casting to ${_device.name}');
    });

    testWidgets('a chosen-but-offline device is blue but not "connected"',
        (tester) async {
      await pumpIcon(tester, overrides: [
        castConnectionProvider.overrideWithValue(CastConnection.chosenOffline),
        castDisplayDeviceProvider.overrideWithValue(_device),
      ]);

      expect(iconOf(tester).icon, Icons.cast_rounded);
      expect(iconOf(tester).color, Colors.blue);
      expect(tooltipOf(tester), '${_device.name} — not connected');
    });

    testWidgets('shows a progress ring while connecting', (tester) async {
      await pumpIcon(tester, overrides: [
        castConnectionProvider.overrideWithValue(CastConnection.connecting),
        castDisplayDeviceProvider.overrideWithValue(_device),
      ]);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tooltipOf(tester), 'Connecting to ${_device.name}…');
    });

    testWidgets(
        'the connecting ring stays inside the 36px pill it has to sit in',
        (tester) async {
      await pumpIcon(tester, overrides: [
        castConnectionProvider.overrideWithValue(CastConnection.connecting),
        castDisplayDeviceProvider.overrideWithValue(_device),
      ]);

      // GlassPill is 36px tall with 12px of horizontal padding; anything
      // taller than the pill's own icon slot would force the bar to grow.
      expect(
        tester.getSize(find.byType(CircularProgressIndicator)).height,
        lessThanOrEqualTo(18),
      );
    });

    testWidgets('every glyph it can draw is from the _rounded family',
        (tester) async {
      // icon_family_test.dart scans this file's source for `Icons.*`, but only
      // a render proves the branch actually selected a rounded glyph.
      for (final connection in CastConnection.values) {
        await pumpIcon(tester, overrides: [
          castConnectionProvider.overrideWithValue(connection),
          castDisplayDeviceProvider.overrideWithValue(_device),
        ]);

        expect(
          iconOf(tester).icon,
          anyOf(Icons.cast_rounded, Icons.cast_connected_rounded),
          reason: '$connection drew a glyph outside the chrome icon family',
        );
      }
    });
  });

  group('castChromeActionFor', () {
    // `ChromeTopBar` decides whether to draw the pill at all from whether this
    // is null. The capability check therefore cannot live inside the glyph: a
    // widget that returned an empty box would leave an empty glass pill
    // floating in the top-right corner on web.
    testWidgets('is null when the build cannot cast at all', (tester) async {
      Widget? action;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.web()),
        ],
        child: Consumer(builder: (context, ref, _) {
          action = castChromeActionFor(ref);
          return const SizedBox.shrink();
        }),
      ));

      expect(action, isNull);
    });

    testWidgets('is a glyph when any cast protocol is available',
        (tester) async {
      for (final capabilities in const [
        CastCapabilities.full(),
        CastCapabilities.iOS(),
      ]) {
        Widget? action;
        await tester.pumpWidget(ProviderScope(
          overrides: [
            castCapabilitiesProvider.overrideWithValue(capabilities),
          ],
          child: Consumer(builder: (context, ref, _) {
            action = castChromeActionFor(ref);
            return const SizedBox.shrink();
          }),
        ));

        expect(action, isA<CastChromeIcon>());
      }
    });
  });

  group('parity with CastButton', () {
    /// The chrome's rounded counterpart of a bare-family cast glyph.
    IconData roundedCounterpart(IconData bare) {
      if (bare == Icons.cast) return Icons.cast_rounded;
      if (bare == Icons.cast_connected) return Icons.cast_connected_rounded;
      fail('CastButton drew an unexpected cast glyph: $bare');
    }

    // Both affordances render the same state machine. A glyph that agreed on
    // four states and disagreed on the fifth is exactly the drift the shared
    // visuals helper exists to prevent, and it would only ever be noticed on
    // whichever screen the reviewer happened not to be looking at.
    for (final connection in CastConnection.values) {
      testWidgets('$connection means the same thing in both affordances',
          (tester) async {
        final overrides = [
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.full()),
          castConnectionProvider.overrideWithValue(connection),
          castDisplayDeviceProvider.overrideWithValue(_device),
        ];

        await pumpIcon(tester, overrides: overrides);
        final chromeGlyph = iconOf(tester).icon;
        final chromeTooltip = tooltipOf(tester);

        await tester.pumpWidget(ProviderScope(
          overrides: overrides,
          child: MaterialApp(
            home: Scaffold(body: CastButton(onPressed: () {})),
          ),
        ));
        await tester.pump();

        final button = tester.widget<IconButton>(
          find.byKey(const Key('cast-button')),
        );
        final buttonGlyph = tester
            .widget<Icon>(find.descendant(
              of: find.byKey(const Key('cast-button')),
              matching: find.byType(Icon),
            ))
            .icon;

        expect(chromeGlyph, roundedCounterpart(buttonGlyph!),
            reason: 'the two families must stay in lockstep on whether this '
                'state counts as connected');
        expect(chromeTooltip, button.tooltip);
      });
    }
  });
}
