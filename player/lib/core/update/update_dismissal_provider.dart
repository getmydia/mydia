import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

/// Hive box holding update versions the user has waved off.
const String updateDismissalBoxName = 'update_dismissals';

/// The box recording which versions the user dismissed.
final updateDismissalBoxProvider = FutureProvider<Box<bool>>((ref) async {
  return Hive.openBox<bool>(updateDismissalBoxName);
});

/// The set of update versions the user has dismissed.
///
/// Keyed on the version string, so dismissing 0.15.0 says nothing about
/// 0.16.0 and the banner returns on its own without any expiry logic.
class UpdateDismissalNotifier extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async {
    // Fails open. A broken box must not silence a real update, which is the
    // same call `CompatibilityNotifier` makes for the same reason.
    try {
      final box = await ref.watch(updateDismissalBoxProvider.future);
      return box.keys
          .cast<String>()
          .where((key) => box.get(key) == true)
          .toSet();
    } catch (e) {
      debugPrint('[UpdateDismissalNotifier] could not read dismissals: $e');
      return <String>{};
    }
  }

  /// Hides the banner for [version], permanently.
  Future<void> dismiss(String version) async {
    try {
      final box = await ref.read(updateDismissalBoxProvider.future);
      await box.put(version, true);
    } catch (e) {
      debugPrint('[UpdateDismissalNotifier] could not persist dismissal: $e');
    }

    // The banner calls this fire-and-forget. If the provider is disposed
    // while the Hive write is in flight, writing to state throws
    // UnmountedRefException as an unhandled async error rather than a caught
    // one. Same guard, same reason, as CompatibilityNotifier.dismiss.
    if (!ref.mounted) return;

    state = AsyncValue.data({...?state.value, version});
  }
}

/// Update versions the user has dismissed.
final updateDismissalProvider =
    AsyncNotifierProvider<UpdateDismissalNotifier, Set<String>>(
  UpdateDismissalNotifier.new,
);
