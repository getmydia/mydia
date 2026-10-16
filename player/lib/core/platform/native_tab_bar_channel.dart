import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'native_tab_bar_support.dart';

/// One native tab. `toMap` is what `NativeTabSpec(channelValue:)` reads.
@immutable
class NativeTab {
  const NativeTab({
    required this.id,
    required this.title,
    required this.symbol,
    this.badge,
    this.enabled = true,
  });

  final String id;
  final String title;

  /// An SF Symbol name.
  final String symbol;
  final String? badge;
  final bool enabled;

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'symbol': symbol,
        'badge': badge,
        'enabled': enabled,
      };

  @override
  bool operator ==(Object other) =>
      other is NativeTab &&
      other.id == id &&
      other.title == title &&
      other.symbol == symbol &&
      other.badge == badge &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, title, symbol, badge, enabled);
}

/// The cast accessory. `toMap` is what `CastAccessoryModel(channelValue:)`
/// reads.
@immutable
class NativeAccessory {
  const NativeAccessory({
    required this.title,
    this.subtitle,
    this.artwork,
    this.symbol,
    this.playing,
  });

  final String title;
  final String? subtitle;

  /// An artwork URL. The accessory shows [symbol] until it loads, and keeps
  /// [symbol] if it fails.
  final String? artwork;

  /// An SF Symbol name.
  final String? symbol;

  /// Null when the state has no play/pause control.
  final bool? playing;

  Map<String, Object?> toMap() => {
        'title': title,
        'subtitle': subtitle,
        'artwork': artwork,
        'symbol': symbol,
        'playing': playing,
      };

  @override
  bool operator ==(Object other) =>
      other is NativeAccessory &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.artwork == artwork &&
      other.symbol == symbol &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(title, subtitle, artwork, symbol, playing);

  @override
  String toString() => 'NativeAccessory(${toMap()})';
}

/// What the native bar tells Flutter.
sealed class NativeTabBarEvent {
  const NativeTabBarEvent();
}

/// The user tapped an enabled tab. Flutter decides whether to go there.
final class NativeTabSelected extends NativeTabBarEvent {
  const NativeTabSelected(this.id);
  final String id;
}

/// Where the native chrome sits over the Flutter view, in points. Each edge
/// is 0 while the chrome is hidden.
@immutable
class NativeInsets {
  const NativeInsets({this.top = 0, this.leading = 0, this.bottom = 0});

  final double top;

  /// The content's leading edge: the sidebar's width while it shows.
  final double leading;

  /// The bar plus the accessory plus the home indicator.
  final double bottom;

  bool get isZero => top == 0 && leading == 0 && bottom == 0;

  /// Reads the map the iPad sends, or the bare bottom the iPhone sends.
  static NativeInsets? fromChannel(Object? value) => switch (value) {
        num() => NativeInsets(bottom: value.toDouble()),
        {'top': num top, 'leading': num leading, 'bottom': num bottom} =>
          NativeInsets(
            top: top.toDouble(),
            leading: leading.toDouble(),
            bottom: bottom.toDouble(),
          ),
        _ => null,
      };

  @override
  bool operator ==(Object other) =>
      other is NativeInsets &&
      other.top == top &&
      other.leading == leading &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(top, leading, bottom);

  @override
  String toString() =>
      'NativeInsets(top: $top, leading: $leading, bottom: $bottom)';
}

/// The native chrome's insets changed. All zero while it is hidden.
final class NativeInsetsChanged extends NativeTabBarEvent {
  const NativeInsetsChanged(this.insets);
  final NativeInsets insets;

  /// What the iPhone bar reads.
  double get bottom => insets.bottom;
}

/// The iPad's width class changed. [sidebar] is true at regular width, where
/// the sidebar shows; false at compact width, where iPadOS shows a tab bar.
final class NativeLayoutChanged extends NativeTabBarEvent {
  const NativeLayoutChanged({required this.sidebar});
  final bool sidebar;
}

final class NativeAccessoryTapped extends NativeTabBarEvent {
  const NativeAccessoryTapped();
}

final class NativeAccessoryPlayPause extends NativeTabBarEvent {
  const NativeAccessoryPlayPause();
}

/// The Dart end of `mydia/native-tab-bar`.
///
/// Every setter drops a value equal to the last one sent, so widgets can call
/// them on every build without spamming the channel. A failure on the native
/// side is logged and swallowed: the bar is chrome, never a reason to crash.
class NativeTabBarChannel {
  NativeTabBarChannel({MethodChannel? channel})
      : _channel = channel ?? NativeTabBarSupport.channel {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final _events = StreamController<NativeTabBarEvent>.broadcast();

  List<NativeTab>? _tabs;
  Map<String, Object?>? _sidebar;
  String? _selected;
  bool? _visible;

  // Native starts with no accessory, which is what null means.
  NativeAccessory? _accessory;

  Stream<NativeTabBarEvent> get events => _events.stream;

  Future<void> setTabs(List<NativeTab> tabs) {
    final sent = _tabs;
    if (sent != null && listEquals(sent, tabs)) return Future.value();
    final value = List<NativeTab>.unmodifiable(tabs);
    _tabs = value;
    // Native's tabs are now the bar's, not the sidebar's.
    _sidebar = null;
    return _send('setTabs', [for (final tab in tabs) tab.toMap()], () {
      if (identical(_tabs, value)) _tabs = null;
    });
  }

  Future<void> setSidebar(Map<String, Object?> payload) {
    final sent = _sidebar;
    if (sent != null && const DeepCollectionEquality().equals(sent, payload)) {
      return Future.value();
    }
    _sidebar = payload;
    // Native now holds the sidebar's tabs, not the bar's.
    _tabs = null;
    return _send('setSidebar', payload, () {
      if (identical(_sidebar, payload)) _sidebar = null;
    });
  }

  /// Asks native for the width class once: true at regular width (sidebar
  /// shown), false at compact width. Null when it cannot answer.
  Future<bool?> queryLayout() async {
    try {
      final answer = await _channel.invokeMethod<Object?>('layout');
      return switch (answer) {
        {'sidebar': bool sidebar} => sidebar,
        _ => null,
      };
    } on MissingPluginException catch (e) {
      debugPrint('[NativeTabBar] layout: plugin missing: $e');
    } on PlatformException catch (e) {
      debugPrint('[NativeTabBar] layout failed: $e');
    }
    return null;
  }

  Future<void> select(String id) {
    if (id == _selected) return Future.value();
    _selected = id;
    return _send('select', id, () {
      if (_selected == id) _selected = null;
    });
  }

  Future<void> setVisible(bool visible) {
    if (visible == _visible) return Future.value();
    _visible = visible;
    return _send('setVisible', visible, () {
      if (_visible == visible) _visible = null;
    });
  }

  Future<void> setAccessory(NativeAccessory? accessory) {
    if (accessory == _accessory) return Future.value();
    _accessory = accessory;
    return _send('setAccessory', accessory?.toMap(), () {
      if (_accessory == accessory) _accessory = _unsentAccessory;
    });
  }

  // A sentinel no real accessory equals, so a failed send is retried even
  // when the failed value was null (which otherwise means "none sent").
  static const _unsentAccessory = NativeAccessory(title: '\u0000unsent');

  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_events.close());
  }

  /// Sends, and when the send fails runs [invalidate] so the dedup cache does
  /// not claim a value native never received. [invalidate] only clears the
  /// cache when it still holds the failed value.
  Future<void> _send(
    String method,
    Object? arguments,
    void Function() invalidate,
  ) async {
    if (!await _invoke(method, arguments)) invalidate();
  }

  Future<bool> _invoke(String method, Object? arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
      return true;
    } on MissingPluginException catch (e) {
      debugPrint('[NativeTabBar] $method: plugin missing: $e');
    } on PlatformException catch (e) {
      debugPrint('[NativeTabBar] $method failed: $e');
    }
    return false;
  }

  Future<Object?> _onCall(MethodCall call) async {
    final arguments = call.arguments;
    final NativeTabBarEvent? event = switch (call.method) {
      'tabSelected' when arguments is String => NativeTabSelected(arguments),
      'insetsChanged' => switch (NativeInsets.fromChannel(arguments)) {
          final insets? => NativeInsetsChanged(insets),
          null => null,
        },
      'layoutChanged' => switch (arguments) {
          {'sidebar': bool sidebar} => NativeLayoutChanged(sidebar: sidebar),
          _ => null,
        },
      'accessoryTapped' => const NativeAccessoryTapped(),
      'accessoryPlayPause' => const NativeAccessoryPlayPause(),
      _ => null,
    };
    if (event == null) {
      debugPrint('[NativeTabBar] ignored ${call.method}($arguments)');
    } else if (!_events.isClosed) {
      _events.add(event);
    }
    return null;
  }
}

/// The one channel the shell's bar and the cast accessory share.
final nativeTabBarChannelProvider = Provider<NativeTabBarChannel>((ref) {
  final channel = NativeTabBarChannel();
  ref.onDispose(channel.dispose);
  return channel;
});
