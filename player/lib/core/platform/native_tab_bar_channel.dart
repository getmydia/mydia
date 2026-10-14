import 'dart:async';

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

/// The bar plus the accessory, measured from the screen bottom with the home
/// indicator included. 0 while the bar is hidden.
final class NativeInsetsChanged extends NativeTabBarEvent {
  const NativeInsetsChanged(this.bottom);
  final double bottom;
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
  String? _selected;
  bool? _visible;

  // Native starts with no accessory, which is what null means.
  NativeAccessory? _accessory;

  Stream<NativeTabBarEvent> get events => _events.stream;

  Future<void> setTabs(List<NativeTab> tabs) {
    final sent = _tabs;
    if (sent != null && listEquals(sent, tabs)) return Future.value();
    _tabs = List.unmodifiable(tabs);
    return _invoke('setTabs', [for (final tab in tabs) tab.toMap()]);
  }

  Future<void> select(String id) {
    if (id == _selected) return Future.value();
    _selected = id;
    return _invoke('select', id);
  }

  Future<void> setVisible(bool visible) {
    if (visible == _visible) return Future.value();
    _visible = visible;
    return _invoke('setVisible', visible);
  }

  Future<void> setAccessory(NativeAccessory? accessory) {
    if (accessory == _accessory) return Future.value();
    _accessory = accessory;
    return _invoke('setAccessory', accessory?.toMap());
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_events.close());
  }

  Future<void> _invoke(String method, Object? arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException catch (e) {
      debugPrint('[NativeTabBar] $method: plugin missing: $e');
    } on PlatformException catch (e) {
      debugPrint('[NativeTabBar] $method failed: $e');
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    final arguments = call.arguments;
    final NativeTabBarEvent? event = switch (call.method) {
      'tabSelected' when arguments is String => NativeTabSelected(arguments),
      'insetsChanged' when arguments is num =>
        NativeInsetsChanged(arguments.toDouble()),
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
