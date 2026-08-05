import 'package:flutter/material.dart';

import '../../../../core/update/updaters/macos_updater.dart';
import 'settings_row.dart';

/// macOS-only opt-in for Sparkle's beta channel.
///
/// The stored value lives in macOS user defaults on the Swift side, so this
/// reads it once on mount rather than holding it in app state. Sparkle asks
/// for the allowed channels through a synchronous callback that cannot wait
/// on Dart, which is why Swift owns it.
///
/// The platform gate lives at the call site, not in here, so a `flutter test`
/// host on Linux can still exercise the row.
class BetaChannelRow extends StatefulWidget {
  const BetaChannelRow({super.key});

  @override
  State<BetaChannelRow> createState() => _BetaChannelRowState();
}

class _BetaChannelRowState extends State<BetaChannelRow> {
  bool _enabled = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = _generation;
    final enabled = await MacOSUpdater.betaChannelEnabled();
    if (mounted && generation == _generation) {
      setState(() => _enabled = enabled);
    }
  }

  Future<void> _set(bool value) async {
    final generation = ++_generation;
    setState(() => _enabled = value);

    final accepted = await MacOSUpdater.setBetaChannel(value);
    if (!mounted || generation != _generation) return;
    if (accepted) return;

    // The write did not land, so the optimistic value is a lie. Ask the host
    // what it actually holds rather than reverting to the previous value,
    // which may itself have been an unconfirmed optimistic update from a tap
    // that is still in flight.
    final actual = await MacOSUpdater.betaChannelEnabled();
    if (mounted && generation == _generation) {
      setState(() => _enabled = actual);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsRow.toggle(
      key: const Key('beta-channel-switch'),
      icon: Icons.science_outlined,
      title: 'Include beta versions',
      // Sparkle has no downgrade path, so opting back out leaves you where you
      // are. Saying so here is cheaper than building a rollback nobody expects.
      subtitle: 'Prerelease builds see less testing, and turning this back off '
          'keeps your current version until a stable release catches up.',
      value: _enabled,
      onChanged: _set,
    );
  }
}
