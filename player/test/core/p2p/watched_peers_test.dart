import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/watched_peers.dart';

String addr(String id) => '{"id":"$id","addrs":[]}';

void main() {
  late Set<String> connected;
  late List<String> dialed;
  late bool failDials;

  WatchedPeers build() => WatchedPeers(
        nodeIdFor: (peer) =>
            RegExp(r'"id":"([^"]+)"').firstMatch(peer)?.group(1),
        isConnected: connected.contains,
        dial: (a) async {
          dialed.add(a);
          if (failDials) throw Exception('unreachable');
        },
      );

  setUp(() {
    connected = {};
    dialed = [];
    failDials = false;
  });

  test('redials each watched peer that drops', () {
    fakeAsync((async) {
      final peers = build()
        ..watch(addr('home'))
        ..watch(addr('guest'));

      peers.onDisconnected('home');
      peers.onDisconnected('guest');
      async.elapse(const Duration(seconds: 2));

      expect(dialed, unorderedEquals([addr('home'), addr('guest')]));
    });
  });

  test('watching a second peer keeps the first watched', () {
    final peers = build()
      ..watch(addr('home'))
      ..watch(addr('guest'));

    expect(peers.isWatched('home'), isTrue);
    expect(peers.isWatched('guest'), isTrue);
  });

  test('ignores a peer it does not watch', () {
    fakeAsync((async) {
      final peers = build()..watch(addr('home'));

      peers.onDisconnected('other-player');
      async.elapse(const Duration(seconds: 10));

      expect(dialed, isEmpty);
    });
  });

  test('gives up after three failed attempts, per peer', () {
    fakeAsync((async) {
      failDials = true;
      final peers = build()
        ..watch(addr('home'))
        ..watch(addr('guest'));

      peers.onDisconnected('home');
      async.elapse(const Duration(seconds: 30));
      expect(dialed.where((a) => a == addr('home')), hasLength(3));

      // The guest's budget is its own.
      peers.onDisconnected('guest');
      async.elapse(const Duration(seconds: 30));
      expect(dialed.where((a) => a == addr('guest')), hasLength(3));
    });
  });

  test('a reconnect cancels the pending redial and resets the budget', () {
    fakeAsync((async) {
      final peers = build()..watch(addr('home'));

      peers.onDisconnected('home');
      peers.onConnected('home');
      async.elapse(const Duration(seconds: 10));

      expect(dialed, isEmpty);
    });
  });

  test('skips the redial when the peer is already back', () {
    fakeAsync((async) {
      final peers = build()..watch(addr('home'));

      peers.onDisconnected('home');
      connected.add('home');
      async.elapse(const Duration(seconds: 2));

      expect(dialed, isEmpty);
    });
  });

  test('unwatch cancels a pending redial', () {
    fakeAsync((async) {
      final peers = build()..watch(addr('guest'));

      peers.onDisconnected('guest');
      peers.unwatch(addr('guest'));
      async.elapse(const Duration(seconds: 10));

      expect(dialed, isEmpty);
      expect(peers.isWatched('guest'), isFalse);
    });
  });

  test('clear cancels everything', () {
    fakeAsync((async) {
      final peers = build()
        ..watch(addr('home'))
        ..watch(addr('guest'));

      peers.onDisconnected('home');
      peers.onDisconnected('guest');
      peers.clear();
      async.elapse(const Duration(seconds: 10));

      expect(dialed, isEmpty);
    });
  });

  test('re-watching a peer updates the address it redials', () {
    fakeAsync((async) {
      const moved = '{"id":"home","addrs":["10.0.0.2:1"]}';
      final peers = build()
        ..watch(addr('home'))
        ..watch(moved);

      peers.onDisconnected('home');
      async.elapse(const Duration(seconds: 2));

      expect(dialed, [moved]);
    });
  });
}
