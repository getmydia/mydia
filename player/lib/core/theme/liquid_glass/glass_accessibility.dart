import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/native_tab_bar_channel.dart';

/// The two system settings the glass follows. Flutter exposes neither
/// Reduce Transparency nor (on macOS) Increase Contrast, so native reports
/// them over `mydia/native-tab-bar`.
@immutable
class GlassAccessibility {
  const GlassAccessibility({
    this.reduceTransparency = false,
    this.increaseContrast = false,
  });

  static const none = GlassAccessibility();

  final bool reduceTransparency;
  final bool increaseContrast;

  static GlassAccessibility? fromChannel(Object? value) => switch (value) {
        {
          'reduceTransparency': final bool reduceTransparency,
          'increaseContrast': final bool increaseContrast,
        } =>
          GlassAccessibility(
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast,
          ),
        _ => null,
      };

  @override
  bool operator ==(Object other) =>
      other is GlassAccessibility &&
      other.reduceTransparency == reduceTransparency &&
      other.increaseContrast == increaseContrast;

  @override
  int get hashCode => Object.hash(reduceTransparency, increaseContrast);

  @override
  String toString() => 'GlassAccessibility(reduceTransparency: '
      '$reduceTransparency, increaseContrast: $increaseContrast)';
}

final glassAccessibilityProvider =
    NotifierProvider<GlassAccessibilityNotifier, GlassAccessibility>(
  GlassAccessibilityNotifier.new,
);

/// Queries the flags once, follows native pushes, and re-queries on app resume
/// because iOS does not replay notifications missed while suspended.
class GlassAccessibilityNotifier extends Notifier<GlassAccessibility> {
  /// Forces the platform check in tests. Reset to null in `tearDown`.
  @visibleForTesting
  static bool? debugIsApple;

  static bool get _isApple =>
      debugIsApple ??
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.macOS));

  @override
  GlassAccessibility build() {
    if (!_isApple) return GlassAccessibility.none;
    final channel = ref.watch(nativeTabBarChannelProvider);
    final sub = channel.events.listen((event) {
      if (event is NativeGlassAccessibilityChanged) state = event.value;
    });
    ref.onDispose(sub.cancel);
    final lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_refresh(channel)),
    );
    ref.onDispose(lifecycle.dispose);
    unawaited(_refresh(channel));
    return GlassAccessibility.none;
  }

  /// Bounded like the tab bar probe: no answer in 2 seconds keeps the
  /// current value, and a later push still applies.
  Future<void> _refresh(NativeTabBarChannel channel) async {
    final value = await channel
        .queryGlassAccessibility()
        .timeout(const Duration(seconds: 2), onTimeout: () => null);
    if (value != null && ref.mounted) state = value;
  }
}

/// Carries [GlassAccessibility] to `GlassSurface`, which is a plain
/// `StatelessWidget` used outside any `ProviderScope` in many tests.
class GlassAccessibilityScope extends InheritedWidget {
  const GlassAccessibilityScope({
    super.key,
    required this.value,
    required super.child,
  });

  final GlassAccessibility value;

  static GlassAccessibility of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<GlassAccessibilityScope>()
          ?.value ??
      GlassAccessibility.none;

  @override
  bool updateShouldNotify(GlassAccessibilityScope oldWidget) =>
      oldWidget.value != value;
}

/// Mounted once in `MaterialApp.router`'s builder.
class GlassAccessibilityHost extends ConsumerWidget {
  const GlassAccessibilityHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => GlassAccessibilityScope(
        value: ref.watch(glassAccessibilityProvider),
        child: child,
      );
}
