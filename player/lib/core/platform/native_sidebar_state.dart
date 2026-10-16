/// What the iPad's and Mac's native sidebar reports, held where the shell can watch it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'native_tab_bar_channel.dart';

/// Whether the iPad is at regular width, where the native sidebar shows.
/// At compact width iPadOS turns it into a tab bar, and the shell sends the
/// phone's bar payload instead.
class NativeSidebarRegular extends Notifier<bool> {
  @override
  bool build() {
    final channel = ref.watch(nativeTabBarChannelProvider);
    var eventSeen = false;
    final events = channel.events.listen((event) {
      if (event is NativeLayoutChanged) {
        eventSeen = true;
        state = event.sidebar;
      }
    });
    ref.onDispose(events.cancel);
    unawaited(channel.queryLayout().then((answer) {
      // An event is newer than the answer to a question asked before it.
      if (answer != null && !eventSeen && ref.mounted) state = answer;
    }));
    // A full-screen iPad is regular, so the first frame shows the sidebar.
    return true;
  }
}

final nativeSidebarRegularProvider =
    NotifierProvider<NativeSidebarRegular, bool>(NativeSidebarRegular.new);

/// The last non-zero insets native reported. Zero means the chrome is hidden
/// (a sheet or the player covers the shell), and reflowing the content
/// behind it would make every screen jump, so it is kept as it was.
class NativeSidebarInsets extends Notifier<NativeInsets?> {
  @override
  NativeInsets? build() {
    final events =
        ref.watch(nativeTabBarChannelProvider).events.listen((event) {
      if (event is NativeInsetsChanged &&
          (!event.insets.isZero || event.insets.reportsChrome)) {
        state = event.insets;
      }
    });
    ref.onDispose(events.cancel);
    return null;
  }
}

final nativeSidebarInsetsProvider =
    NotifierProvider<NativeSidebarInsets, NativeInsets?>(
        NativeSidebarInsets.new);
