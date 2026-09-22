import 'log_store.dart';

Future<LogStore?> openLogStore({
  required String sessionId,
  void Function(String reason)? onDisabled,
}) async =>
    null;

List<int> gzipBytes(List<int> input) =>
    throw UnsupportedError('gzip is not available on this platform');
