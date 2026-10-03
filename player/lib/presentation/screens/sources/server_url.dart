/// What the viewer typed as a server address.
library;

/// [text] as a server root, or null when it cannot be one. A bare
/// `host:port` is taken as HTTP, which is how Stash and Jellyfin ship. A
/// reverse-proxy subpath is kept.
Uri? parseServerUrl(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  final path = uri.path.endsWith('/')
      ? uri.path.substring(0, uri.path.length - 1)
      : uri.path;
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path.isEmpty ? null : path,
  );
}
