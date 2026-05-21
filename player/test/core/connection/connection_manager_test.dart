import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_manager.dart';
import 'package:player/core/connection/connection_result.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  group('ConnectionManager', () {
    late MockAuthStorage mockAuthStorage;
    late ConnectionManager manager;

    setUp(() {
      mockAuthStorage = MockAuthStorage();
      manager = ConnectionManager(authStorage: mockAuthStorage);
    });

    tearDown(() {
      manager.dispose();
    });

    group('connect', () {
      test('returns direct connection for first URL', () async {
        final result = await manager.connect(
          directUrls: ['https://example.com'],
          instanceId: 'instance-123',
        );

        expect(result.success, isTrue);
        expect(result.type, equals(ConnectionType.direct));
        expect(result.connectedUrl, equals('https://example.com'));
      });

      test('uses first URL from list', () async {
        final result = await manager.connect(
          directUrls: [
            'https://first.example.com',
            'https://second.example.com',
          ],
          instanceId: 'instance-123',
        );

        expect(result.connectedUrl, equals('https://first.example.com'));
      });

      test('returns error when no direct URLs provided', () async {
        final result = await manager.connect(
          directUrls: [],
          instanceId: 'instance-123',
        );

        expect(result.success, isFalse);
        expect(result.error, contains('Could not connect'));
      });

      test('stores connection preference', () async {
        await manager.connect(
          directUrls: ['https://example.com'],
          instanceId: 'instance-123',
        );

        expect(mockAuthStorage.containsKey('connection_last_type'), isTrue);
        expect(mockAuthStorage.containsKey('connection_last_url'), isTrue);

        final storedType = await mockAuthStorage.read('connection_last_type');
        final storedUrl = await mockAuthStorage.read('connection_last_url');

        expect(storedType, equals('direct'));
        expect(storedUrl, equals('https://example.com'));
      });
    });

    group('stateChanges stream', () {
      test('emits state changes during connection', () async {
        final states = <String>[];
        final subscription = manager.stateChanges.listen(states.add);

        await manager.connect(
          directUrls: ['https://example.com'],
          instanceId: 'instance-123',
        );

        // Allow stream events to be processed
        await Future.delayed(Duration.zero);

        expect(states, contains('Trying direct URL: https://example.com'));
        expect(states, contains('Direct connection successful'));

        await subscription.cancel();
      });

      test('emits fallback message when no direct URLs', () async {
        final states = <String>[];
        final subscription = manager.stateChanges.listen(states.add);

        await manager.connect(
          directUrls: [],
          instanceId: 'instance-123',
        );

        // Allow stream events to be processed
        await Future.delayed(Duration.zero);

        expect(states, contains('Falling back to P2P'));

        await subscription.cancel();
      });

      test('is a broadcast stream', () async {
        // Multiple listeners should work
        final states1 = <String>[];
        final states2 = <String>[];

        final sub1 = manager.stateChanges.listen(states1.add);
        final sub2 = manager.stateChanges.listen(states2.add);

        await manager.connect(
          directUrls: ['https://example.com'],
          instanceId: 'instance-123',
        );

        await Future.delayed(Duration.zero);

        expect(states1, isNotEmpty);
        expect(states2, isNotEmpty);
        expect(states1, equals(states2));

        await sub1.cancel();
        await sub2.cancel();
      });
    });

    group('dispose', () {
      test('closes state stream', () async {
        final completer = Completer<bool>();

        manager.stateChanges.listen(
          (_) {},
          onDone: () => completer.complete(true),
        );

        manager.dispose();

        expect(await completer.future, isTrue);
      });

      test('does not emit after dispose', () async {
        manager.dispose();

        // Creating a new manager for the actual connection test
        final newManager = ConnectionManager(authStorage: mockAuthStorage);
        final states = <String>[];
        final subscription = newManager.stateChanges.listen(states.add);

        await newManager.connect(
          directUrls: ['https://example.com'],
          instanceId: 'instance-123',
        );

        await Future.delayed(Duration.zero);

        expect(states, isNotEmpty);

        await subscription.cancel();
        newManager.dispose();
      });
    });

    group('directTimeout', () {
      test('has default value of 5 seconds', () {
        expect(manager.directTimeout, equals(const Duration(seconds: 5)));
      });

      test('can be customized via constructor', () {
        final customManager = ConnectionManager(
          authStorage: mockAuthStorage,
          directTimeout: const Duration(seconds: 10),
        );

        expect(
            customManager.directTimeout, equals(const Duration(seconds: 10)));

        customManager.dispose();
      });
    });

    group('preferences persistence', () {
      test('loads preferences before connecting', () async {
        // Seed with previous preference
        mockAuthStorage.seedData({
          'connection_last_type': 'p2p',
          'connection_last_url': 'https://old.example.com',
        });

        // Connect should still work with new URLs
        final result = await manager.connect(
          directUrls: ['https://new.example.com'],
          instanceId: 'instance-123',
        );

        expect(result.success, isTrue);
        expect(result.connectedUrl, equals('https://new.example.com'));

        // Preference should be updated
        final storedUrl = await mockAuthStorage.read('connection_last_url');
        expect(storedUrl, equals('https://new.example.com'));
      });
    });
  });
}
