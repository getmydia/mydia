import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/player/platform_features.dart';

/// Whether this platform has a local-network permission pane worth linking to.
///
/// Only macOS and iOS gate local network access behind a user-visible switch.
/// `CastFailureKind.discoveryDenied` also fires on Android when the multicast
/// lock cannot be acquired — which no settings pane fixes — so the affordance
/// must not follow that failure onto other platforms. Without this, an
/// Android discovery failure offered a button that deep-linked to an Apple
/// URL and then printed macOS instructions on a phone.
bool localNetworkSettingsAvailable() =>
    PlatformFeatures.isMacOS || PlatformFeatures.isIOS;

/// Deep link to the OS pane that grants local-network access.
///
/// The macOS anchor is version-sensitive. Apple has renamed panes before, and
/// there is no way to ask whether a scheme will resolve before trying it,
/// which is why [openLocalNetworkSettings] always checks the result.
Uri localNetworkSettingsUri({required bool isIOS}) => Uri.parse(
      isIOS
          ? 'app-settings:'
          : 'x-apple.systempreferences:com.apple.preference.security'
              '?Privacy_LocalNetwork',
    );

/// What to tell the user when the deep link will not open.
///
/// A button that silently does nothing is worse than no button, so this text
/// is the guaranteed floor: it always leaves the user with something they can
/// act on by hand.
String localNetworkSettingsFallback({required bool isIOS}) => isIOS
    ? 'Open Settings > Mydia > Local Network and enable it.'
    : 'Open System Settings > Privacy & Security > Local Network and '
        'enable Mydia.';

/// Opens the local-network permission pane, or explains how to reach it.
///
/// Shared by [LocalNetworkSettingsButton] and by the cast error snackbar's
/// action, so the deep link and its fallback have exactly one implementation.
Future<void> openLocalNetworkSettings(BuildContext context) async {
  // Defence in depth. Nothing should offer this on a platform with no such
  // pane — both call sites check [localNetworkSettingsAvailable] first — but
  // firing an Apple-only URL scheme on Android would fail and then print
  // macOS instructions, which is worse than doing nothing.
  if (!localNetworkSettingsAvailable()) {
    debugPrint('[LocalNetworkSettings] No settings pane on this platform.');
    return;
  }

  final isIOS = PlatformFeatures.isIOS;
  var launched = false;

  try {
    launched = await launchUrl(
      localNetworkSettingsUri(isIOS: isIOS),
      mode: LaunchMode.externalApplication,
    );
  } catch (e) {
    debugPrint('[LocalNetworkSettings] Could not open settings: $e');
  }

  if (launched || !context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(localNetworkSettingsFallback(isIOS: isIOS)),
    duration: const Duration(seconds: 6),
  ));
}

/// Button form of [openLocalNetworkSettings], for surfaces with room for one.
///
/// Renders nothing on platforms with no local-network pane, so the surfaces
/// that show it for `discoveryDenied` — which is not Apple-only — do not have
/// to branch themselves.
class LocalNetworkSettingsButton extends StatelessWidget {
  /// Overrides the platform check. Tests only; production reads the real
  /// platform, which a `flutter test` host can never report as Apple.
  final bool? available;

  const LocalNetworkSettingsButton({super.key, this.available});

  @override
  Widget build(BuildContext context) {
    if (!(available ?? localNetworkSettingsAvailable())) {
      return const SizedBox.shrink();
    }

    return TextButton.icon(
      key: const Key('local-network-settings-button'),
      onPressed: () => openLocalNetworkSettings(context),
      icon: const Icon(Icons.settings, size: 18),
      label: const Text('Open Settings'),
    );
  }
}
