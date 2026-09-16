import 'package:flutter/foundation.dart';
import 'package:player/native/lib.dart' as native;

/// Free and total bytes on a volume.
class DiskSpace {
  const DiskSpace({required this.free, required this.total});

  final int free;
  final int total;
}

/// Reports the space on the volume holding a path, or null when it cannot
/// be measured.
typedef DiskSpaceProbe = Future<DiskSpace?> Function(String path);

/// [DiskSpaceProbe] backed by the Rust bridge.
Future<DiskSpace?> nativeDiskSpace(String path) async {
  try {
    final space = await native.availableDiskSpace(path: path);
    return DiskSpace(free: space.free.toInt(), total: space.total.toInt());
  } catch (e) {
    debugPrint('[DiskSpace] Could not measure $path: $e');
    return null;
  }
}
