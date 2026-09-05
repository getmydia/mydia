import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/auth_status.dart';
import '../../core/compatibility/compatibility_provider.dart';
import '../../core/graphql/graphql_provider.dart';
import '../../core/player/platform_features.dart';
import '../../core/theme/colors.dart';
import '../../core/update/platform_updater.dart';
import '../../core/update/update_dismissal_provider.dart';
import '../../core/update/update_provider.dart';
import 'banner_button.dart';
import 'update_action.dart';

/// Whether the update banner has anything to say right now.
///
/// A pure function so every suppression rule is reachable without a widget
/// tree, and so the shell can mount the banner unconditionally.
@visibleForTesting
bool shouldShowUpdateBanner({
  required bool supported,
  required bool isMacOS,
  required String? availableVersion,
  required Set<String>? dismissedVersions,
  required bool compatibilityBannerShowing,
  required bool isOffline,
}) {
  // iOS, Android and web update through a store or the Mydia server. macOS
  // has Sparkle, which notifies natively and would double up.
  if (!supported || isMacOS) return false;
  if (availableVersion == null) return false;

  // Null means the dismissal box has not resolved yet. Treating that as
  // "nothing dismissed" would paint the banner on the first frame and yank it
  // away a moment later.
  if (dismissedVersions == null) return false;
  if (dismissedVersions.contains(availableVersion)) return false;

  // The compatibility banner names the server version that forced the issue,
  // which is more use than "a new version exists".
  if (compatibilityBannerShowing) return false;

  // Nothing can be downloaded, and OfflineBanner already owns this slot.
  if (isOffline) return false;

  return true;
}

/// Announces an available player update at the top of the shell.
///
/// Renders nothing unless there is something actionable to say, so it sits
/// unconditionally in the shell next to [OfflineBanner] and
/// [CompatibilityBanner].
///
/// Mounting this is also what makes the update check run at all. `updateProvider`
/// is a lazy NotifierProvider whose `build()` starts the GitHub query, and
/// before this banner existed its only watchers were on the Settings screen.
class UpdateBanner extends ConsumerWidget {
  /// Overrides the platform-support check. Tests only: a `flutter test` host
  /// on Linux always reports a supported platform, so the unsupported branch
  /// is otherwise unreachable. Mirrors [UpdateCard.supportedOverride].
  final bool? supportedOverride;

  /// Opens the release notes. Tests only, so the Notes action can be observed
  /// without a url_launcher platform implementation.
  final UrlLauncher? launcher;

  const UpdateBanner({super.key, this.supportedOverride, this.launcher});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateState = ref.watch(updateProvider);
    final update = updateState.availableUpdate;

    // `.value` and not `.valueOrNull`: riverpod 3.2.1 has no valueOrNull, and
    // `.value` returns null on AsyncError rather than rethrowing.
    final compatibility = ref.watch(compatibilityProvider).value;

    final visible = shouldShowUpdateBanner(
      supported:
          supportedOverride ?? PlatformUpdater.supportedOnCurrentPlatform,
      isMacOS: PlatformFeatures.isMacOS,
      availableVersion: update?.version,
      dismissedVersions: ref.watch(updateDismissalProvider).value,
      compatibilityBannerShowing: compatibility != null &&
          compatibility.showBanner &&
          compatibility.verdict.isPlayerBehind,
      isOffline: ref.watch(authStateProvider).value == AuthStatus.offlineMode,
    );

    // The null check is redundant with `visible`, and present so the compiler
    // can promote `update` below.
    if (!visible || update == null) return const SizedBox.shrink();

    final failed = updateState.error != null;
    final color = failed ? AppColors.error : AppColors.info;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border(
          bottom: BorderSide(color: color.withValues(alpha: 0.3), width: 1),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Icon(Icons.system_update, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                failed
                    ? updateState.error!
                    : 'Mydia Player ${update.version} is available.',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 12),
            BannerButton(
              label: failed ? 'Retry' : 'Update',
              color: color,
              isLoading: updateState.isApplying,
              onPressed: () => startUpdate(context, ref),
            ),
            const SizedBox(width: 8),
            BannerButton(
              label: 'Notes',
              color: color,
              onPressed: () => _openReleaseNotes(update.releaseNotesUrl),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              color: color,
              visualDensity: VisualDensity.compact,
              tooltip: 'Dismiss',
              onPressed: () => ref
                  .read(updateDismissalProvider.notifier)
                  .dismiss(update.version),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openReleaseNotes(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await (launcher ??
        (Uri u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
  }
}
