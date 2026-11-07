import 'dart:async';
import 'dart:io' show SocketException;

import 'package:dbus/dbus.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/linux_accent.dart';

const _ns = 'org.freedesktop.appearance';
const _key = 'accent-color';

DBusValue rgb(double r, double g, double b) =>
    DBusStruct([DBusDouble(r), DBusDouble(g), DBusDouble(b)]);

PortalSettingChange change(DBusValue value,
        {String namespace = _ns, String key = _key}) =>
    (namespace: namespace, key: key, value: DBusVariant(value));

class _FakePortal implements PortalSettingsClient {
  final readOneResult = Completer<DBusValue>();
  Object? readOneError;
  DBusValue? readResult;
  Object? readError;
  bool closed = false;
  final _changes = StreamController<PortalSettingChange>.broadcast();

  void emit(PortalSettingChange c) => _changes.add(c);

  @override
  Future<DBusValue> readOne(String namespace, String key) {
    final error = readOneError;
    if (error != null) return Future.error(error);
    return readOneResult.future;
  }

  @override
  Future<DBusValue> read(String namespace, String key) {
    final error = readError;
    if (error != null) return Future.error(error);
    final result = readResult;
    if (result == null) return Future.error(StateError('read not scripted'));
    return Future.value(result);
  }

  @override
  Stream<PortalSettingChange> get changes => _changes.stream;

  @override
  Future<void> close() async {
    closed = true;
    await _changes.close();
  }
}

DBusUnknownMethodException unknownMethod() => DBusUnknownMethodException(
    DBusMethodErrorResponse('org.freedesktop.DBus.Error.UnknownMethod'));

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  tearDown(() => LinuxAccent.debugIsNativeLinux = null);

  ProviderContainer container(_FakePortal portal) {
    final c = ProviderContainer(overrides: [
      portalSettingsClientProvider.overrideWith((ref) {
        ref.onDispose(portal.close);
        return portal;
      }),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  group('decodePortalAccent', () {
    test('decodes a plain struct, rounding to 8 bits', () {
      expect(decodePortalAccent(rgb(0.2078, 0.5176, 0.8941)),
          const Color(0xFF3584E4));
    });

    test("unwraps variants, including Read's double wrap", () {
      expect(decodePortalAccent(DBusVariant(DBusVariant(rgb(1, 0, 0)))),
          const Color(0xFFFF0000));
    });

    test('out of range means unset', () {
      expect(decodePortalAccent(rgb(-1, -1, -1)), isNull);
      expect(decodePortalAccent(rgb(0.5, 1.2, 0.5)), isNull);
    });

    test('wrong shapes are null', () {
      expect(
          decodePortalAccent(DBusStruct(const [DBusDouble(1), DBusDouble(1)])),
          isNull);
      expect(decodePortalAccent(const DBusString('blue')), isNull);
      expect(
          decodePortalAccent(DBusStruct(
              [const DBusInt32(1), const DBusInt32(1), const DBusInt32(1)])),
          isNull);
    });
  });

  group('LinuxAccent', () {
    test('off Linux it is null and never builds the client', () async {
      LinuxAccent.debugIsNativeLinux = false;
      var built = false;
      final c = ProviderContainer(overrides: [
        portalSettingsClientProvider.overrideWith((ref) {
          built = true;
          return _FakePortal();
        }),
      ]);
      addTearDown(c.dispose);
      expect(c.read(linuxAccentProvider), isNull);
      await settle();
      expect(built, isFalse);
    });

    test('takes the read value, then follows SettingChanged', () async {
      LinuxAccent.debugIsNativeLinux = true;
      final portal = _FakePortal();
      final c = container(portal);
      expect(c.read(linuxAccentProvider), isNull);
      portal.readOneResult.complete(DBusVariant(rgb(1, 0, 0)));
      await settle();
      expect(c.read(linuxAccentProvider), const Color(0xFFFF0000));
      portal.emit(change(rgb(0, 1, 0)));
      await settle();
      expect(c.read(linuxAccentProvider), const Color(0xFF00FF00));
    });

    test('falls back to Read on UnknownMethod', () async {
      LinuxAccent.debugIsNativeLinux = true;
      final portal = _FakePortal()
        ..readOneError = unknownMethod()
        ..readResult = DBusVariant(DBusVariant(rgb(0, 0, 1)));
      final c = container(portal);
      c.read(linuxAccentProvider);
      await settle();
      expect(c.read(linuxAccentProvider), const Color(0xFF0000FF));
    });

    test('no portal: stays null without an unhandled error', () async {
      LinuxAccent.debugIsNativeLinux = true;
      final portal = _FakePortal()
        ..readOneError = DBusMethodResponseException(DBusMethodErrorResponse(
            'org.freedesktop.DBus.Error.ServiceUnknown'))
        ..readError = StateError('unreachable');
      final c = container(portal);
      expect(c.read(linuxAccentProvider), isNull);
      await settle();
      expect(c.read(linuxAccentProvider), isNull);
    });

    test('no session bus: stays null without an unhandled error', () async {
      LinuxAccent.debugIsNativeLinux = true;
      final c = ProviderContainer(overrides: [
        portalSettingsClientProvider
            .overrideWith((ref) => throw const SocketException('no bus')),
      ]);
      addTearDown(c.dispose);
      expect(c.read(linuxAccentProvider), isNull);
      await settle();
      expect(c.read(linuxAccentProvider), isNull);
    });

    test('ignores other keys and namespaces', () async {
      LinuxAccent.debugIsNativeLinux = true;
      final portal = _FakePortal();
      final c = container(portal);
      c.read(linuxAccentProvider);
      portal.readOneResult.complete(DBusVariant(rgb(1, 0, 0)));
      await settle();
      portal.emit(change(const DBusUint32(1), key: 'color-scheme'));
      portal
          .emit(change(rgb(0, 1, 0), namespace: 'org.gnome.desktop.interface'));
      await settle();
      expect(c.read(linuxAccentProvider), const Color(0xFFFF0000));
    });

    test('a signal before the read is not overwritten', () async {
      LinuxAccent.debugIsNativeLinux = true;
      final portal = _FakePortal();
      final c = container(portal);
      c.read(linuxAccentProvider);
      portal.emit(change(rgb(0, 1, 0)));
      await settle();
      portal.readOneResult.complete(DBusVariant(rgb(1, 0, 0)));
      await settle();
      expect(c.read(linuxAccentProvider), const Color(0xFF00FF00));
    });

    test('an unset accent from the portal is null', () async {
      LinuxAccent.debugIsNativeLinux = true;
      final portal = _FakePortal();
      final c = container(portal);
      c.read(linuxAccentProvider);
      portal.readOneResult.complete(DBusVariant(rgb(1, 0, 0)));
      await settle();
      portal.emit(change(rgb(-1, -1, -1)));
      await settle();
      expect(c.read(linuxAccentProvider), isNull);
    });

    test('disposal closes the client', () async {
      LinuxAccent.debugIsNativeLinux = true;
      final portal = _FakePortal();
      final c = ProviderContainer(overrides: [
        portalSettingsClientProvider.overrideWith((ref) {
          ref.onDispose(portal.close);
          return portal;
        }),
      ]);
      c.read(linuxAccentProvider);
      c.dispose();
      await settle();
      expect(portal.closed, isTrue);
    });
  });
}
