/// LOCAL CHANGE (mydia, #252): not part of upstream Cargokit.
///
/// Upstream builds native libraries with `rustup run stable`, which names a
/// toolchain explicitly and therefore overrides rust-toolchain.toml,
/// RUSTUP_TOOLCHAIN and any pinned toolchain on PATH. The compiler that
/// produced the shipped .so files was whatever the host called stable. This
/// resolves the repo's declared pin so the build can name it instead.

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:toml/toml.dart';

/// Returns the `[toolchain] channel` from the nearest `rust-toolchain.toml` at
/// or above [startDir].
///
/// Returns null when no file is found, when it declares no channel, or when it
/// cannot be parsed. Callers are expected to fall back to upstream's `stable`,
/// which keeps behaviour identical for trees without a toolchain file.
String? resolveToolchainChannel(String startDir) {
  var dir = Directory(path.normalize(path.absolute(startDir)));
  while (true) {
    final file = File(path.join(dir.path, 'rust-toolchain.toml'));
    if (file.existsSync()) {
      return _channelOf(file);
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      return null;
    }
    dir = parent;
  }
}

String? _channelOf(File file) {
  try {
    final document = TomlDocument.parse(file.readAsStringSync()).toMap();
    final toolchain = document['toolchain'];
    if (toolchain is! Map) {
      return null;
    }
    final channel = toolchain['channel'];
    if (channel is String && channel.isNotEmpty) {
      return channel;
    }
    return null;
  } catch (_) {
    return null;
  }
}
