import 'dart:async';
import 'dart:io' show pid;

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../build_channel.dart';
import '../remote/remote_control_intent.dart';
import 'media_session_state.dart';
import 'system_media_session.dart';

/// The well-known name GNOME, KDE and playerctl look for. The Flatpak default
/// session-bus policy lets the app own `org.mpris.MediaPlayer2.$FLATPAK_ID`,
/// so this needs no `--own-name` finish-arg.
const mprisBusName = 'org.mpris.MediaPlayer2.dev.mydia.player';

const _rootInterface = 'org.mpris.MediaPlayer2';
const _playerInterface = 'org.mpris.MediaPlayer2.Player';
const _noTrack = '/org/mpris/MediaPlayer2/TrackList/NoTrack';

/// Seeks smaller than this are indistinguishable from timer jitter.
const _seekedThreshold = Duration(seconds: 2);

/// An object path for [trackId]. Path elements allow only `[A-Za-z0-9_]`.
String mprisTrackPath(String? trackId) {
  if (trackId == null || trackId.isEmpty) return _noTrack;
  final safe = trackId.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  return '/dev/mydia/player/track/$safe';
}

/// MPRIS 2 over the session bus, written directly on `package:dbus`.
class MprisMediaSession implements SystemMediaSession {
  MprisMediaSession._(this._client, this._object, this.busName);

  final DBusClient _client;
  final _MprisObject _object;

  /// The name actually owned: [mprisBusName] or an `.instance<pid>` fallback.
  final String busName;

  /// Registers the object and claims a name. Returns null when neither the
  /// primary nor the instance name could be owned. Never closes [client].
  static Future<MprisMediaSession?> connect({
    required DBusClient client,
    required Duration Function() position,
    DateTime Function() now = DateTime.now,
    int? pid,
  }) async {
    final object = _MprisObject(position: position, now: now);
    await client.registerObject(object);
    for (final name in [mprisBusName, '$mprisBusName.instance${pid ?? _pid}']) {
      final reply = await client
          .requestName(name, flags: {DBusRequestNameFlag.doNotQueue});
      if (reply == DBusRequestNameReply.primaryOwner) {
        return MprisMediaSession._(client, object, name);
      }
    }
    debugPrint('[MediaSession] could not own an MPRIS name');
    await client.unregisterObject(object);
    await object.close();
    return null;
  }

  @override
  Stream<RemoteControlIntent> get commands => _object.commands.stream;

  @override
  Stream<void> get raiseRequests => _object.raises.stream;

  @override
  Future<void> update(MediaSessionState state) => _object.apply(state);

  @override
  Future<void> dispose() async {
    try {
      await _client.releaseName(busName);
      await _client.unregisterObject(_object);
    } catch (e) {
      debugPrint('[MediaSession] MPRIS teardown failed: $e');
    }
    await _object.close();
  }
}

int get _pid => pid;

class _MprisObject extends DBusObject {
  _MprisObject({required Duration Function() position, required this.now})
      : _position = position,
        super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  final Duration Function() _position;
  final DateTime Function() now;
  final commands = StreamController<RemoteControlIntent>.broadcast();
  final raises = StreamController<void>.broadcast();

  MediaSessionState _state = MediaSessionState.stopped;
  DateTime? _stateAt;

  // The position and time MPRIS clients (GNOME Shell, KDE, playerctl) are
  // known to have last synchronised against: the last Seeked signal we sent,
  // or the last update where PlaybackStatus or the track changed, since
  // clients re-read Position on both of those. _jumped extrapolates from
  // this baseline rather than from the immediately preceding update, because
  // during a buffering stall several updates less than the threshold apart
  // each look like small drift on their own even though, measured from the
  // client's actual (unmoving) sync point, the drift accumulates.
  Duration? _syncPosition;
  DateTime? _syncAt;
  bool _syncPlaying = false;

  // apply() awaits DBus IO (emitPropertiesChanged, then emitSignal), so two
  // calls started back to back race: whichever one's IO happens to settle
  // first lands on the bus first, even when it was the newer state. Chaining
  // every apply onto this future serializes them in call order regardless of
  // how their individual awaits interleave. catchError keeps a failed apply
  // from wedging the chain for everyone after it; the failure still reaches
  // that apply's own caller through the Future apply() returns.
  Future<void> _applying = Future.value();

  Future<void> close() async {
    await commands.close();
    await raises.close();
  }

  Future<void> apply(MediaSessionState next) {
    final result = _applying.then((_) => _applyNow(next));
    _applying = result.catchError((_) {});
    return result;
  }

  Future<void> _applyNow(MediaSessionState next) async {
    final previous = _state;
    final before = _playerProperties(previous);
    _state = next;
    _stateAt = now();
    final after = _playerProperties(next);

    final changed = <String, DBusValue>{
      for (final entry in after.entries)
        if (before[entry.key] != entry.value) entry.key: entry.value,
    };
    if (changed.isNotEmpty) {
      await emitPropertiesChanged(_playerInterface, changedProperties: changed);
    }

    final jumped = _jumped(previous, next);
    if (jumped) {
      await emitSignal(_playerInterface, 'Seeked',
          [DBusInt64(next.position.inMicroseconds)]);
    }

    // Resync the baseline whenever a client is known to re-read Position:
    // right after we tell it to (Seeked), when the track changes, when
    // PlaybackStatus changes, or on the very first update (no baseline yet).
    if (jumped ||
        _syncAt == null ||
        previous.trackId != next.trackId ||
        previous.status != next.status) {
      _syncPosition = next.position;
      _syncAt = _stateAt;
      _syncPlaying = next.status == MediaSessionStatus.playing;
    }
  }

  /// True when [next] is the same track at a position the client-sync
  /// baseline cannot explain.
  bool _jumped(MediaSessionState previous, MediaSessionState next) {
    final syncAt = _syncAt;
    final syncPosition = _syncPosition;
    if (syncAt == null ||
        syncPosition == null ||
        previous.trackId == null ||
        previous.trackId != next.trackId) {
      return false;
    }
    // A buffering stall is still reported as MediaSessionStatus.playing (MPRIS
    // has no separate status for it) with Rate 1.0, so MPRIS clients (GNOME
    // Shell, KDE) extrapolate the progress bar forward through the stall from
    // their own last sync point (the last Seeked, or the last time
    // PlaybackStatus or the track changed), not from our previous update.
    // During a stall, updates less than the threshold apart each look like
    // small drift measured against each other, but measured against the
    // client's unmoving sync point the drift accumulates, and Seeked is
    // exactly how MPRIS tells clients to resync when the position changed in
    // a way the current playing state doesn't explain.
    final elapsed = _syncPlaying ? now().difference(syncAt) : Duration.zero;
    final expected = syncPosition + elapsed;
    return (next.position - expected).abs() > _seekedThreshold;
  }

  // Position is deliberately absent: MPRIS says it must not be signalled.
  Map<String, DBusValue> _playerProperties(MediaSessionState s) {
    final active = s.status != MediaSessionStatus.stopped;
    return {
      'PlaybackStatus': DBusString(switch (s.status) {
        MediaSessionStatus.playing => 'Playing',
        MediaSessionStatus.paused => 'Paused',
        MediaSessionStatus.stopped => 'Stopped',
      }),
      'Metadata': DBusDict.stringVariant(_metadata(s)),
      'Volume': DBusDouble(s.volume),
      'Rate': const DBusDouble(1.0),
      'MinimumRate': const DBusDouble(1.0),
      'MaximumRate': const DBusDouble(1.0),
      'CanGoNext': DBusBoolean(active && s.canGoNext),
      'CanGoPrevious': DBusBoolean(active && s.canGoPrevious),
      'CanPlay': DBusBoolean(active),
      'CanPause': DBusBoolean(active),
      'CanSeek': DBusBoolean(active && s.canSeek),
      'CanControl': const DBusBoolean(true),
    };
  }

  Map<String, DBusValue> _metadata(MediaSessionState s) => {
        'mpris:trackid': DBusObjectPath(mprisTrackPath(
            s.status == MediaSessionStatus.stopped ? null : s.trackId)),
        if (s.status != MediaSessionStatus.stopped) ...{
          'xesam:title': DBusString(s.title),
          if (s.subtitle != null)
            'xesam:artist': DBusArray.string([s.subtitle!]),
          if (s.duration > Duration.zero)
            'mpris:length': DBusInt64(s.duration.inMicroseconds),
          if (s.artworkPath != null)
            'mpris:artUrl': DBusString(Uri.file(s.artworkPath!).toString()),
        },
      };

  Map<String, DBusValue> _rootProperties() => {
        'CanQuit': const DBusBoolean(false),
        'CanRaise': const DBusBoolean(true),
        'CanSetFullscreen': const DBusBoolean(false),
        'Fullscreen': const DBusBoolean(false),
        'HasTrackList': const DBusBoolean(false),
        'Identity': DBusString(BuildChannel.current.appName),
        'DesktopEntry': const DBusString('dev.mydia.player'),
        'SupportedUriSchemes': DBusArray.string(const []),
        'SupportedMimeTypes': DBusArray.string(const []),
      };

  Map<String, DBusValue>? _propertiesOf(String interface) =>
      switch (interface) {
        _rootInterface => _rootProperties(),
        _playerInterface => {
            ..._playerProperties(_state),
            'Position': DBusInt64(_position().inMicroseconds),
          },
        _ => null,
      };

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = _propertiesOf(interface)?[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    final properties = _propertiesOf(interface);
    return properties == null
        ? DBusMethodErrorResponse.unknownInterface()
        : DBusGetAllPropertiesResponse(properties);
  }

  @override
  Future<DBusMethodResponse> setProperty(
      String interface, String name, DBusValue value) async {
    if (interface == _playerInterface && name == 'Volume') {
      if (value is! DBusDouble) return DBusMethodErrorResponse.invalidArgs();
      _emit(VolumeIntent(level: value.value.clamp(0.0, 1.0).toDouble()));
      return DBusMethodSuccessResponse();
    }
    if (_propertiesOf(interface)?.containsKey(name) ?? false) {
      return DBusMethodErrorResponse.propertyReadOnly();
    }
    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    try {
      return switch (call.interface) {
        _rootInterface => _handleRoot(call),
        _playerInterface => _handlePlayer(call),
        _ => DBusMethodErrorResponse.unknownInterface(),
      };
    } catch (e) {
      debugPrint('[MediaSession] MPRIS ${call.name} failed: $e');
      return DBusMethodErrorResponse.failed('$e');
    }
  }

  DBusMethodResponse _handleRoot(DBusMethodCall call) {
    switch (call.name) {
      case 'Raise':
        if (!raises.isClosed) raises.add(null);
      case 'Quit':
        break; // CanQuit is false; the spec allows a no-op.
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
    return DBusMethodSuccessResponse();
  }

  DBusMethodResponse _handlePlayer(DBusMethodCall call) {
    final s = _state;
    final active = s.status != MediaSessionStatus.stopped;
    switch (call.name) {
      case 'Play':
        if (active) _emit(const TransportIntent(TransportAction.play));
      case 'Pause':
        if (active) _emit(const TransportIntent(TransportAction.pause));
      case 'PlayPause':
        if (active) {
          _emit(TransportIntent(s.status == MediaSessionStatus.playing
              ? TransportAction.pause
              : TransportAction.play));
        }
      case 'Stop':
        if (active) _emit(const TransportIntent(TransportAction.stop));
      case 'Next':
        if (active && s.canGoNext) {
          _emit(const EpisodeStepIntent(EpisodeStep.next));
        }
      case 'Previous':
        if (active && s.canGoPrevious) {
          _emit(const EpisodeStepIntent(EpisodeStep.previous));
        }
      case 'Seek':
        if (call.signature != DBusSignature('x')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        if (active && s.canSeek) {
          final offset = Duration(microseconds: call.values[0].asInt64());
          _seekTo(_clamp(_position() + offset, s.duration));
        }
      case 'SetPosition':
        if (call.signature != DBusSignature('ox')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        final track = call.values[0].asObjectPath().value;
        final target = Duration(microseconds: call.values[1].asInt64());
        final current = mprisTrackPath(s.trackId);
        if (active &&
            s.canSeek &&
            track == current &&
            !target.isNegative &&
            target <= s.duration) {
          _seekTo(target);
        }
      case 'OpenUri':
        break;
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
    return DBusMethodSuccessResponse();
  }

  Duration _clamp(Duration value, Duration max) {
    if (value.isNegative) return Duration.zero;
    return value > max ? max : value;
  }

  void _seekTo(Duration target) =>
      _emit(TransportIntent(TransportAction.seek, position: target));

  void _emit(RemoteControlIntent intent) {
    if (!commands.isClosed) commands.add(intent);
  }

  @override
  List<DBusIntrospectInterface> introspect() => [
        DBusIntrospectInterface(_rootInterface, methods: [
          DBusIntrospectMethod('Raise'),
          DBusIntrospectMethod('Quit'),
        ], properties: [
          for (final e in _rootProperties().entries)
            DBusIntrospectProperty(e.key, e.value.signature,
                access: DBusPropertyAccess.read),
        ]),
        DBusIntrospectInterface(_playerInterface, methods: [
          for (final name in [
            'Next',
            'Previous',
            'Pause',
            'PlayPause',
            'Stop',
            'Play',
          ])
            DBusIntrospectMethod(name),
          DBusIntrospectMethod('Seek', args: [
            DBusIntrospectArgument(
                DBusSignature('x'), DBusArgumentDirection.in_,
                name: 'Offset'),
          ]),
          DBusIntrospectMethod('SetPosition', args: [
            DBusIntrospectArgument(
                DBusSignature('o'), DBusArgumentDirection.in_,
                name: 'TrackId'),
            DBusIntrospectArgument(
                DBusSignature('x'), DBusArgumentDirection.in_,
                name: 'Position'),
          ]),
          DBusIntrospectMethod('OpenUri', args: [
            DBusIntrospectArgument(
                DBusSignature('s'), DBusArgumentDirection.in_,
                name: 'Uri'),
          ]),
        ], signals: [
          DBusIntrospectSignal('Seeked', args: [
            DBusIntrospectArgument(
                DBusSignature('x'), DBusArgumentDirection.out,
                name: 'Position'),
          ]),
        ], properties: [
          for (final e in _propertiesOf(_playerInterface)!.entries)
            DBusIntrospectProperty(e.key, e.value.signature,
                access: e.key == 'Volume'
                    ? DBusPropertyAccess.readwrite
                    : DBusPropertyAccess.read),
        ]),
      ];
}
