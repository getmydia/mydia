import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/sources/sources_providers.dart'
    show mydiaAccountCountProvider;
import '../../../../core/update/update_provider.dart';
import '../../../widgets/connection_status_dot.dart';
import '../settings_controller.dart';
import 'settings_dialog.dart';
import 'settings_dialog_sidebar.dart';

/// Wires the sidebar's account card, connection dot and update pill to the
/// providers `SettingsScreen` reads for the same facts.
class SettingsSidebarStatus extends ConsumerWidget {
  const SettingsSidebarStatus({
    super.key,
    required this.selected,
    required this.compact,
    required this.onSelect,
    this.location,
  });

  final SettingsCategory selected;
  final bool compact;
  final ValueChanged<SettingsCategory> onSelect;

  /// The shell location the dialog opened over, which says which source the
  /// connection dot describes. Null draws no dot.
  final String? location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider).value;
    // As SettingsScreen does: with several Mydia accounts this would name
    // only the bound one.
    final manyMydiaAccounts = ref.watch(mydiaAccountCountProvider) > 1;
    final username = settings?.username ?? '';
    final serverUrl = settings?.serverUrl ?? '';
    final account = manyMydiaAccounts || (username.isEmpty && serverUrl.isEmpty)
        ? null
        : SettingsSidebarAccount(username: username, serverUrl: serverUrl);
    final updateAvailable = ref.watch(
      updateProvider.select((s) => s.availableUpdate != null),
    );
    final at = location;
    return SettingsDialogSidebar(
      selected: selected,
      compact: compact,
      onSelect: onSelect,
      account: account,
      // The shell's 10px dot, drawn at the sidebar's 7px.
      connectionStatus: at == null
          ? null
          : SizedBox.square(
              dimension: 7,
              child: ConnectionStatusDot(location: at),
            ),
      updateAvailable: updateAvailable,
    );
  }
}
