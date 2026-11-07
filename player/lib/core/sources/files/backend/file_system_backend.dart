/// One file or directory returned by a [FileSystemBackend].
class FileEntry {
  const FileEntry({
    required this.path,
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
    this.identity,
    this.unreadable = false,
  });

  /// Listed, but the server refused to say what it is (a WebDAV entry
  /// answered 403). It is neither read nor descended into, and what the
  /// index holds for it, and under it, is kept as it was.
  final bool unreadable;

  /// Absolute path for local folders, decoded server path for WebDAV.
  final String path;

  /// Where a directory really is, when more than one [path] can lead to it
  /// (a local folder reached through a symbolic link): its resolved path. A
  /// walk visits each identity once. Null means [path] is the identity.
  final String? identity;

  /// The last path segment.
  final String name;
  final bool isDir;

  /// Bytes; 0 for directories.
  final int size;
  final DateTime modified;

  @override
  String toString() => 'FileEntry($path, dir: $isDir, size: $size'
      '${unreadable ? ', unreadable' : ''})';
}

/// What the player needs to open a file: a URL and the headers it requires.
class PlayableFile {
  const PlayableFile({required this.url, this.headers = const {}});

  final String url;
  final Map<String, String> headers;
}

/// Why a backend call failed. Later layers match on the subclasses.
sealed class BackendFailure implements Exception {
  const BackendFailure([this.message]);

  final String? message;

  String get _label;

  @override
  String toString() => message == null ? _label : '$_label: $message';
}

/// The host or folder could not be reached (offline, DNS, timeout, bad status).
final class BackendUnreachable extends BackendFailure {
  const BackendUnreachable([super.message]);
  @override
  String get _label => 'BackendUnreachable';
}

/// The server rejected the credentials.
final class BackendUnauthorized extends BackendFailure {
  const BackendUnauthorized([super.message]);
  @override
  String get _label => 'BackendUnauthorized';
}

/// The OS denied access to a local folder that used to be readable.
final class BackendPermissionLost extends BackendFailure {
  const BackendPermissionLost([super.message]);
  @override
  String get _label => 'BackendPermissionLost';
}

/// The requested path does not exist.
final class BackendNotFound extends BackendFailure {
  const BackendNotFound([super.message]);
  @override
  String get _label => 'BackendNotFound';
}

/// Protocol seam over a place that holds media files.
abstract interface class FileSystemBackend {
  /// One level of [dir]; throws [BackendFailure].
  Future<List<FileEntry>> list(String dir);

  /// The entry at [path], or null when it is gone.
  Future<FileEntry?> stat(String path);

  Future<PlayableFile> playable(String path);

  /// Throws [BackendFailure] when the backend's root cannot be reached. A
  /// backend with a root (a local folder, a WebDAV base URL) checks that root;
  /// a rootless one succeeds.
  Future<void> probe();
}
