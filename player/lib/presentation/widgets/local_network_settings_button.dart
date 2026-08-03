import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/player/platform_features.dart';

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
class LocalNetworkSettingsButton extends StatelessWidget {
  const LocalNetworkSettingsButton({super.key});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: const Key('local-network-settings-button'),
      onPressed: () => openLocalNetworkSettings(context),
      icon: const Icon(Icons.settings, size: 18),
      label: const Text('Open Settings'),
    );
  }
}
