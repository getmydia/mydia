import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/app.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/cast_mini_controller.dart';
import 'package:player/presentation/widgets/nav/desktop_sidebar.dart';
import 'package:player/presentation/widgets/toast/toast_layer.dart';
import 'package:player/presentation/widgets/toast/toast_models.dart';
import 'package:player/presentation/widgets/toast/toaster.dart';

class _FakeAuthNotifier extends AuthStateNotifier {
  _FakeAuthNotifier(this._initial);

  final AsyncValue<AuthStatus> _initial;

  @override
  AsyncValue<AuthStatus> build() => _initial;
}

const _device = CastDevice(
  id: 'd1',
  name: 'Cottage Chromecast',
  protocol: CastProtocolKind.chromecast,
);

const _session = CastSession(
  device: _device,
  playbackState: CastPlaybackState.playing,
  mediaInfo: CastMediaInfo(
    title: 'The Long Aurora - S01E02',
    duration: Duration(minutes: 44),
    position: Duration(seconds: 29),
  ),
);

/// Pumps the real `MyApp`, so what is under test is where `app.dart` mounts
/// the layer: above the cast bar, beside a real shell with its sidebar.
void main() {
  testWidgets('a toast clears the desktop sidebar and the cast bar',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(overrides: [
      castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
      authStateProvider.overrideWith(() =>
          _FakeAuthNotifier(const AsyncValue.data(AuthStatus.authenticated))),
      asyncGraphqlClientProvider
          .overrideWith((ref) => Completer<GraphQLClient>().future),
      castSessionProvider.overrideWith((ref) => Stream.value(_session)),
      castSessionManagerProvider
          .overrideWith((ref) => Completer<CastSessionManager>().future),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MyApp(),
    ));
    await tester.pump();

    final bar = find.byType(CastMiniController);
    final sidebar = find.byType(GlassSidebarPanel);
    expect(bar, findsOneWidget);
    expect(sidebar, findsOneWidget);

    showToast(tester.element(bar), 'Saved');
    // Not pumpAndSettle: the shell's loading indicators never settle.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final pill = tester.getRect(find.byKey(const Key('toast-pill')));
    // The SafeArea the obstruction wraps, i.e. the bar's own box.
    final barTop = tester
        .getRect(
            find.descendant(of: bar, matching: find.byType(SafeArea)).first)
        .top;
    // The column the sidebar leaves free, in window coordinates. The sidebar
    // and the layer are both measured, so nothing here is pinned to the
    // sidebar's own width or to the 1400 window: a pill that ignored the left
    // claim would centre on the window instead of on this column.
    final sidebarRect = tester.getRect(sidebar);
    final layerRect = tester.getRect(find.byType(ToastLayer));
    const gutter = ToastMetrics.gutter;
    final freeLeft = sidebarRect.right + gutter;
    final freeRight = layerRect.right - gutter;
    expect(pill.center.dx, closeTo((freeLeft + freeRight) / 2, 1.0),
        reason: 'the pill centres in the column the sidebar leaves free, so '
            'this fails the moment the sidebar stops claiming its edge');
    expect(pill.left, greaterThanOrEqualTo(sidebarRect.right));
    expect(pill.bottom, lessThanOrEqualTo(barTop - 16 + 0.5));
  });
}
