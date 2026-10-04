import 'package:flutter/foundation.dart';
import 'package:player/core/sources/connection/source_connection.dart';
import 'package:player/core/sources/media_source.dart';

/// A connection that is always up at [baseUri].
class FixedConnection implements SourceConnection {
  FixedConnection(this.baseUri);

  final Uri baseUri;
  final failures = <Uri>[];
  int refreshes = 0;
  final _status = ValueNotifier(SourceConnectionStatus.local);

  @override
  ValueListenable<SourceConnectionStatus> get status => _status;

  @override
  Uri? get currentBase => baseUri;

  @override
  Future<Uri> base() async => baseUri;

  @override
  Future<void> refresh() async => refreshes++;

  @override
  void reportFailure(Uri base) => failures.add(base);

  @override
  void dispose() => _status.dispose();
}
