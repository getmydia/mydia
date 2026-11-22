/// "Manage backup": the row under the backup switch that opens onto the
/// controls a viewer rarely needs (the devices in the backup, the recovery
/// key, moving and deleting it), so the section reads as one switch until
/// asked.
library;

import 'package:material_ui/material_ui.dart';

import '../../../core/theme/palette.dart';
import '../../../core/ui/reduced_motion.dart';
import '../../../l10n/l10n.dart';

class BackupManageDisclosure extends StatefulWidget {
  const BackupManageDisclosure({
    super.key,
    required this.deviceCount,
    required this.children,
  });

  /// How many devices are in the backup, said under the title.
  final int deviceCount;

  /// What opens under the row. Built only while open, so nothing in it
  /// takes focus while closed.
  final List<Widget> children;

  @override
  State<BackupManageDisclosure> createState() => _BackupManageDisclosureState();
}

class _BackupManageDisclosureState extends State<BackupManageDisclosure> {
  static const _duration = Duration(milliseconds: 200);

  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final duration = context.reducedMotionDuration(_duration);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: _open,
          child: ListTile(
            key: const Key('backup-manage'),
            leading: Icon(
              Icons.tune_rounded,
              color: context.palette.textSecondary,
            ),
            title: Text(l10n.backupManage),
            subtitle: Text(l10n.backupManageDevices(widget.deviceCount)),
            trailing: AnimatedRotation(
              turns: _open ? 0.5 : 0,
              duration: duration,
              child: const Icon(Icons.expand_more_rounded),
            ),
            onTap: () => setState(() => _open = !_open),
          ),
        ),
        ClipRect(
          child: AnimatedSize(
            duration: duration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _open
                ? Column(
                    key: const Key('backup-manage-body'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: widget.children,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ),
      ],
    );
  }
}
