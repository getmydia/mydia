/// The Mydia login `AuthService` already holds, as a [MediaSource].
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/sources/item.dart';
import '../../domain/sources/library.dart';
import '../auth/auth_status.dart';
import 'media_source.dart';
import 'mydia/mydia_guest_source.dart';
import 'source.dart';

class MydiaSource extends MediaSource {
  MydiaSource({required this.source, required this.auth});

  @override
  final Source source;

  final AsyncValue<AuthStatus> auth;

  /// Empty on purpose. Mydia's screens predate this layer and consult
  /// nothing here; capabilities are declared as its controllers move
  /// behind [MediaSource]. Artwork is the one call this stub answers.
  @override
  Set<SourceCapability> get capabilities => const {};

  /// Reachable Mydia reports [SourceConnectionStatus.remote]: the existing
  /// connection layer does not distinguish a LAN route from a remote one.
  @override
  SourceConnectionStatus get connection => switch (auth) {
        AsyncData(value: AuthStatus.authenticated) =>
          SourceConnectionStatus.remote,
        AsyncData() => SourceConnectionStatus.unreachable,
        AsyncError() => SourceConnectionStatus.unreachable,
        _ => SourceConnectionStatus.connecting,
      };

  late final ValueNotifier<SourceConnectionStatus> _status =
      ValueNotifier(connection);

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable => _status;

  @override
  T? as<T extends Object>() => null;

  // Mydia's screens predate this interface and stay on their own
  // controllers. Moving them behind it is a later, opt-in migration.
  static Never _ownScreens() => throw UnsupportedError(
      'Mydia browses through its own screens, not MediaSource');

  @override
  Future<List<Library>> libraries() async => _ownScreens();

  @override
  Future<Page<ItemSummary>> browse(LibraryRef library, BrowseQuery query,
          {Cursor? cursor}) async =>
      _ownScreens();

  @override
  Future<ItemDetail> item(ItemRef ref) async => _ownScreens();

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async =>
      _ownScreens();

  @override
  Future<ArtworkRequest?> artwork(ArtworkRef art, {required int width}) async =>
      absoluteArtworkRequest(id, art, width);

  @override
  void dispose() => _status.dispose();
}
