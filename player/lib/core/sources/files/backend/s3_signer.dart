import 'dart:convert';

import 'package:crypto/crypto.dart';

const _emptyPayloadSha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const _algorithm = 'AWS4-HMAC-SHA256';

/// Percent-encodes [s] per the SigV4 rules: every byte except `A-Za-z0-9-_.~`
/// is encoded as uppercase `%XX` over its UTF-8 form. `/` is kept unless
/// [encodeSlash] is true.
String s3UriEncode(String s, {required bool encodeSlash}) {
  final out = StringBuffer();
  for (final b in utf8.encode(s)) {
    final unreserved = (b >= 0x41 && b <= 0x5a) ||
        (b >= 0x61 && b <= 0x7a) ||
        (b >= 0x30 && b <= 0x39) ||
        b == 0x2d ||
        b == 0x5f ||
        b == 0x2e ||
        b == 0x7e;
    if (unreserved || (b == 0x2f && !encodeSlash)) {
      out.writeCharCode(b);
    } else {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// AWS Signature Version 4 signer for S3-compatible endpoints.
class S3Signer {
  S3Signer({
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.region,
    this.service = 's3',
    DateTime Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().toUtc());

  final String accessKeyId;
  final String secretAccessKey;
  final String region;
  final String service;
  final DateTime Function() _clock;

  bool get _isS3 => service == 's3';

  /// Returns the full header map to send: [headers] plus `host`, `x-amz-date`,
  /// `x-amz-content-sha256` (s3 only) and `authorization`. Every header is
  /// signed. [payloadSha256] is the lowercase hex SHA-256 of the body and
  /// defaults to the hash of the empty body.
  Map<String, String> sign({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    String? payloadSha256,
  }) {
    final now = _clock().toUtc();
    final amzDate = _amzDate(now);
    final dateStamp = amzDate.substring(0, 8);
    final payloadHash = payloadSha256 ?? _emptyPayloadSha256;

    final out = <String, String>{
      ...headers,
      'host': _hostHeader(uri),
      'x-amz-date': amzDate,
      if (_isS3) 'x-amz-content-sha256': payloadHash,
    };

    final signed = <String, String>{
      for (final e in out.entries)
        e.key.toLowerCase(): e.value.trim().replaceAll(RegExp(r'\s+'), ' '),
    };
    final names = signed.keys.toList()..sort();
    final canonicalHeaders = names.map((n) => '$n:${signed[n]}\n').join();
    final signedHeaders = names.join(';');

    final canonicalRequest = [
      method.toUpperCase(),
      _canonicalPath(uri),
      _canonicalQuery(uri),
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final scope = '$dateStamp/$region/$service/aws4_request';
    final signature = _signature(canonicalRequest, amzDate, dateStamp, scope);
    out['authorization'] = '$_algorithm Credential=$accessKeyId/$scope,'
        'SignedHeaders=$signedHeaders,Signature=$signature';
    return out;
  }

  /// Returns [uri] with the `X-Amz-*` query parameters added. Only `host` is
  /// signed and the payload is unsigned.
  Uri presign({
    required String method,
    required Uri uri,
    required Duration expires,
  }) {
    final now = _clock().toUtc();
    final amzDate = _amzDate(now);
    final dateStamp = amzDate.substring(0, 8);
    final scope = '$dateStamp/$region/$service/aws4_request';

    final params = <String, List<String>>{
      for (final e in uri.queryParametersAll.entries) e.key: [...e.value],
      'X-Amz-Algorithm': [_algorithm],
      'X-Amz-Credential': ['$accessKeyId/$scope'],
      'X-Amz-Date': [amzDate],
      'X-Amz-Expires': ['${expires.inSeconds}'],
      'X-Amz-SignedHeaders': ['host'],
    };
    final withParams = uri.replace(queryParameters: params);

    final canonicalRequest = [
      method.toUpperCase(),
      _canonicalPath(withParams),
      _canonicalQuery(withParams),
      'host:${_hostHeader(uri)}\n',
      'host',
      'UNSIGNED-PAYLOAD',
    ].join('\n');

    final signature = _signature(canonicalRequest, amzDate, dateStamp, scope);
    params['X-Amz-Signature'] = [signature];
    return uri.replace(queryParameters: params);
  }

  String _signature(
    String canonicalRequest,
    String amzDate,
    String dateStamp,
    String scope,
  ) {
    final stringToSign = [
      _algorithm,
      amzDate,
      scope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');
    var key = _hmac(utf8.encode('AWS4$secretAccessKey'), dateStamp);
    key = _hmac(key, region);
    key = _hmac(key, service);
    key = _hmac(key, 'aws4_request');
    return Hmac(sha256, key).convert(utf8.encode(stringToSign)).toString();
  }

  List<int> _hmac(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  String _amzDate(DateTime t) {
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(t.year, 4)}${p(t.month)}${p(t.day)}'
        'T${p(t.hour)}${p(t.minute)}${p(t.second)}Z';
  }

  /// The `host` value a client sends for [uri], which [sign] and [presign]
  /// both sign. `Uri.host` drops an IPv6 literal's brackets; the header
  /// keeps them, and S3 signs what it receives.
  String _hostHeader(Uri uri) {
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    return uri.hasPort && uri.port != defaultPort ? '$host:${uri.port}' : host;
  }

  /// Each segment is decoded and re-encoded so the canonical path matches what
  /// S3 computes whatever `Uri` left unescaped. Empty segments are kept: S3
  /// paths are never normalized.
  String _canonicalPath(Uri uri) {
    if (uri.path.isEmpty) return '/';
    return uri.path
        .split('/')
        .map((seg) => s3UriEncode(_decodeSegment(seg), encodeSlash: true))
        .join('/');
  }

  String _decodeSegment(String seg) {
    try {
      return Uri.decodeComponent(seg);
    } on FormatException {
      return seg;
    }
  }

  String _canonicalQuery(Uri uri) {
    final pairs = <List<String>>[];
    for (final e in uri.queryParametersAll.entries) {
      for (final v in e.value) {
        pairs.add([
          s3UriEncode(e.key, encodeSlash: true),
          s3UriEncode(v, encodeSlash: true),
        ]);
      }
    }
    pairs.sort((a, b) {
      final c = a[0].compareTo(b[0]);
      return c != 0 ? c : a[1].compareTo(b[1]);
    });
    return pairs.map((p) => '${p[0]}=${p[1]}').join('&');
  }
}
