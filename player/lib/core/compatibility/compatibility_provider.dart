import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../graphql/graphql_provider.dart';
import 'compatibility.dart';
import 'compatibility_service.dart';
import 'compatibility_verdict.dart';

/// Hive box holding dismissals of the soft compatibility nudge.
const compatibilityDismissalBoxName = 'compatibility_dismissals';

/// This player's own version, e.g. "0.9.0".
///
/// Split into its own provider so tests can override it without mocking the
/// platform channel PackageInfo reads from.
final playerVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
});

/// The box recording which nudges the user has dismissed.
final compatibilityDismissalBoxProvider =
    FutureProvider<Box<bool>>((ref) async {
  return Hive.openBox<bool>(compatibilityDismissalBoxName);
});

/// What the banner needs to render itself.
class CompatibilityState {
  final CompatibilityVerdict verdict;

  /// This player's version, always known.
  final String playerVersion;

  /// The connected server's version, null when we could not ask.
  final String? serverVersion;

  /// The floor that was not met, null when nothing is wrong.
  final String? requiredVersion;

  /// Whether the user dismissed this exact mismatch.
  final bool dismissed;

  const CompatibilityState({
    required this.verdict,
    required this.playerVersion,
    this.serverVersion,
    this.requiredVersion,
    this.dismissed = false,
  });

  /// Whether to paint the banner right now.
  ///
  /// A required verdict ignores [dismissed] entirely, so a stale key in the box
  /// can never suppress a hard warning.
  bool get showBanner {
    if (!verdict.showsBanner) return false;
    if (verdict.isRequired) return true;
    return !dismissed;
  }

  /// The dismissal key for this exact mismatch.
  ///
  /// Keyed on the version pair so dismissing a nudge for one pair does not
  /// suppress it after either side moves.
  String get dismissalKey =>
      '${verdict.name}:$playerVersion:${serverVersion ?? 'unknown'}';

  CompatibilityState copyWith({bool? dismissed}) => CompatibilityState(
        verdict: verdict,
        playerVersion: playerVersion,
        serverVersion: serverVersion,
        requiredVersion: requiredVersion,
        dismissed: dismissed ?? this.dismissed,
      );
}

/// Compares this player against the connected server and exposes the verdict.
///
/// Never throws into the widget tree: every failure resolves to
/// [CompatibilityVerdict.unknown], which renders nothing.
class CompatibilityNotifier extends AsyncNotifier<CompatibilityState> {
  @override
  Future<CompatibilityState> build() async {
    final playerVersion = await ref.watch(playerVersionProvider.future);
    final client = ref.watch(graphqlClientProvider);

    final server = await CompatibilityService(client).fetch();
    final verdict = evaluateCompatibility(
      playerVersion: playerVersion,
      server: server,
    );

    final state = CompatibilityState(
      verdict: verdict,
      playerVersion: playerVersion,
      serverVersion: server?.version,
      requiredVersion: _floorFor(verdict, server),
    );

    if (!state.verdict.isDismissible) return state;

    final box = await ref.watch(compatibilityDismissalBoxProvider.future);
    return state.copyWith(dismissed: box.get(state.dismissalKey) ?? false);
  }

  /// The floor the losing side failed to clear, for the banner copy.
  static String? _floorFor(
    CompatibilityVerdict verdict,
    ServerCompatibilityInfo? server,
  ) {
    switch (verdict) {
      case CompatibilityVerdict.playerUpdateRequired:
        return server?.minPlayerVersion;
      case CompatibilityVerdict.playerUpdateRecommended:
        return server?.recommendedPlayerVersion;
      case CompatibilityVerdict.serverUpdateRequired:
        return Compatibility.minServerVersion;
      case CompatibilityVerdict.serverUpdateRecommended:
        return Compatibility.recommendedServerVersion;
      case CompatibilityVerdict.compatible:
      case CompatibilityVerdict.unknown:
        return null;
    }
  }

  /// Hides a soft nudge for this exact version pair, permanently.
  ///
  /// A no-op for required verdicts: they are not dismissible and must not write
  /// a key that a later read could mistake for consent.
  Future<void> dismiss() async {
    final current = state.value;
    if (current == null || !current.verdict.isDismissible) return;

    try {
      final box = await ref.read(compatibilityDismissalBoxProvider.future);
      await box.put(current.dismissalKey, true);
    } catch (e) {
      debugPrint('[CompatibilityNotifier] could not persist dismissal: $e');
    }

    state = AsyncValue.data(current.copyWith(dismissed: true));
  }

  /// Re-asks the server. Call on resume, or after the connection changes.
  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

/// The connected server's compatibility with this player.
final compatibilityProvider =
    AsyncNotifierProvider<CompatibilityNotifier, CompatibilityState>(
  CompatibilityNotifier.new,
);
