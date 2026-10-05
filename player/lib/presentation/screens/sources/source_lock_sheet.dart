/// Choosing how one server is kept from whoever else uses this device.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/lock/pin_store.dart';
import '../../../core/sources/lock/source_lock_controller.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/sources/store/source_records.dart';
import '../../widgets/toast/toaster.dart';
import 'pin_pad.dart';

Future<void> changeServerLock(BuildContext context, WidgetRef ref,
    SourceAccountRecord record, SourceServer server) async {
  final anyLock = ref.read(sourceLocksProvider).isNotEmpty;
  if (anyLock && !ref.read(sourceLockProvider)) {
    await context.push(unlockLocation());
    return;
  }
  final choice = await showModalBottomSheet<SourceLock>(
    context: context,
    showDragHandle: true,
    builder: (context) => _LockSheet(current: record.lockOf(server.id)),
  );
  if (choice == null ||
      choice == record.lockOf(server.id) ||
      !context.mounted) {
    return;
  }
  final toaster = Toaster.of(context);
  final pins = ref.read(pinStoreProvider);
  try {
    if (choice != SourceLock.none && !await pins.hasPin()) {
      if (!context.mounted) return;
      final pin = await showPinSetupDialog(context);
      if (pin == null) return;
      await pins.setPin(pin);
    }
    await ref
        .read(sourceRecordsProvider.notifier)
        .setServerLock(record.account.id, server.id, choice);
  } catch (_) {
    toaster.show('Could not change the lock.', kind: ToastKind.error);
    return;
  }
  if (choice == SourceLock.hidden && !ref.read(sourceLockProvider)) {
    toaster.show('${server.name} is hidden. Use Show hidden servers to see '
        'it again.');
  }
}

class _LockSheet extends StatelessWidget {
  const _LockSheet({required this.current});

  final SourceLock current;

  @override
  Widget build(BuildContext context) {
    Widget choice(SourceLock lock, String title, String subtitle) =>
        RadioListTile<SourceLock>(
          key: Key('lock-choice-${lock.name}'),
          value: lock,
          title: Text(title),
          subtitle: Text(subtitle),
        );
    return SafeArea(
      child: RadioGroup<SourceLock>(
        groupValue: current,
        onChanged: (value) => Navigator.of(context).pop(value),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            choice(SourceLock.none, 'Not locked', 'Anyone can open it.'),
            choice(SourceLock.locked, 'Locked',
                'Shown with a lock. Opening it asks for Face ID, your passcode or PIN.'),
            choice(SourceLock.hidden, 'Hidden',
                'Not shown anywhere until you unlock.'),
          ],
        ),
      ),
    );
  }
}

/// "Show hidden servers" while locked, "Lock now" while open. Always
/// present, so it says nothing about whether anything is hidden.
class ShowHiddenSourcesRow extends ConsumerWidget {
  const ShowHiddenSourcesRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked = ref.watch(sourceLockProvider);
    return ListTile(
      key: const Key('show-hidden-sources'),
      leading: Icon(unlocked ? Icons.lock_rounded : Icons.visibility_rounded),
      title: Text(unlocked ? 'Lock now' : 'Show hidden servers'),
      onTap: () => unlocked
          ? ref.read(sourceLockProvider.notifier).lock()
          : context.push(unlockLocation()),
    );
  }
}
