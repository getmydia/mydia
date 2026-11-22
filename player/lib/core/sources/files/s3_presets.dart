/// The S3-compatible providers the add screen knows: each one's endpoint
/// template, default region and addressing style.
library;

import '../../../l10n/gen/app_localizations.dart';
import 'backend/s3_backend.dart' show S3Style;

enum S3Preset {
  aws,
  backblazeB2,
  cloudflareR2,
  wasabi,
  other;

  /// The name in the provider list: a brand name, or "Other" worded in
  /// [l10n].
  String label(AppLocalizations l10n) => switch (this) {
    aws => 'Amazon S3', // l10n-ignore: brand name
    backblazeB2 => 'Backblaze B2', // l10n-ignore: brand name
    cloudflareR2 => 'Cloudflare R2', // l10n-ignore: brand name
    wasabi => 'Wasabi', // l10n-ignore: brand name
    other => l10n.filesS3ProviderOther,
  };

  /// Whether the viewer types a region. R2 always signs with `auto`.
  bool get needsRegion => this != cloudflareR2;

  /// Whether the endpoint is built from an account ID (R2).
  bool get needsAccountId => this == cloudflareR2;

  /// Whether the endpoint is typed in full.
  bool get needsEndpoint => this == other;

  /// The region to start from; null when the viewer must type one (B2,
  /// whose endpoint names it).
  String? get defaultRegion => switch (this) {
    backblazeB2 => null,
    cloudflareR2 => 'auto',
    aws || wasabi || other => 'us-east-1',
  };

  /// AWS serves only virtual-hosted requests for buckets made since 2020;
  /// every other provider accepts path style.
  S3Style get defaultStyle => this == aws ? S3Style.vhost : S3Style.path;

  /// The endpoint for [region] (or the default region when empty) and
  /// [accountId]; null for [other], whose endpoint is typed, and when a
  /// needed value is missing or not a host label.
  Uri? endpointFor({String region = '', String accountId = ''}) {
    final r = region.trim().isEmpty ? (defaultRegion ?? '') : region.trim();
    final a = accountId.trim();
    final host = switch (this) {
      aws => _label(r) ? 's3.$r.amazonaws.com' : null,
      backblazeB2 => _label(r) ? 's3.$r.backblazeb2.com' : null,
      cloudflareR2 => _label(a) ? '$a.r2.cloudflarestorage.com' : null,
      wasabi => _label(r) ? 's3.$r.wasabisys.com' : null,
      other => null,
    };
    return host == null ? null : Uri(scheme: 'https', host: host);
  }

  static final _hostLabel = RegExp(r'^[A-Za-z0-9-]+$');
  static bool _label(String s) => _hostLabel.hasMatch(s);
}

/// [typed] as an S3 endpoint: `http` or `https`, a host, an optional port
/// and no path. No scheme means `https`. Null when it cannot be one.
Uri? parseS3Endpoint(String typed) {
  final trimmed = typed.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(
    trimmed.contains('://') ? trimmed : 'https://$trimmed',
  );
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.path.isNotEmpty && uri.path != '/') return null;
  if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) return null;
  return Uri(
    scheme: scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}
