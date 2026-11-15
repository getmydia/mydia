import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'file_system_backend.dart';

const kS3CodeClockSkew = 'RequestTimeTooSkewed';
const kS3CodeWrongRegion = 'WrongRegion';
const kS3CodeTls = 'Tls';
const kS3CodeCannotList = 'CannotList';
const kS3CodeBadKeys = 'BadKeys';
const kS3CodeNoSuchBucket = 'NoSuchBucket';

/// [u] without its query or fragment, so presigned signatures never reach
/// a log line, a message or an exception.
String redactS3Url(Uri u) {
  final s = u.toString();
  final cut = s.indexOf(RegExp(r'[?#]'));
  return cut < 0 ? s : s.substring(0, cut);
}

String? _xmlText(String body, String tag) {
  try {
    final doc = XmlDocument.parse(body);
    final t = doc.findAllElements(tag).firstOrNull?.innerText.trim();
    return (t == null || t.isEmpty) ? null : t;
  } on XmlException {
    return null;
  }
}

/// Maps an S3 error response to a [BackendFailure]. Messages name the host
/// and bucket, never a URL.
BackendFailure s3Failure({
  required int status,
  required String body,
  required String host,
  required String bucket,
  required bool atProbe,
  String? regionHeader,
}) {
  final code = _xmlText(body, 'Code');
  final where = '$host/$bucket';

  if (code == 'RequestTimeTooSkewed') {
    return BackendUnauthorized(
      'S3 rejected the request time at $host (clock skew)',
      kS3CodeClockSkew,
    );
  }
  if (code == 'InvalidAccessKeyId' || code == 'SignatureDoesNotMatch') {
    return BackendUnauthorized(
      'S3 rejected the access keys for $where',
      kS3CodeBadKeys,
    );
  }
  if (status == 403 || code == 'AccessDenied') {
    return atProbe
        ? BackendUnauthorized(
            'S3 denied listing bucket $where',
            kS3CodeCannotList,
          )
        : BackendPermissionLost('S3 denied access to $where');
  }
  if (code == 'NoSuchBucket') {
    return BackendNotFound(
      'Bucket $bucket does not exist at $host',
      kS3CodeNoSuchBucket,
      bucket,
    );
  }
  const wrongRegionCodes = {
    'PermanentRedirect',
    'AuthorizationHeaderMalformed',
    'IllegalLocationConstraintException',
  };
  if (status == 301 || wrongRegionCodes.contains(code)) {
    return BackendUnreachable(
      'Bucket $where is in a different region',
      status,
      kS3CodeWrongRegion,
      _xmlText(body, 'Region') ?? regionHeader,
    );
  }
  if (status == 404) return BackendNotFound('Not found in $where');
  return BackendUnreachable('S3 at $host answered $status', status);
}

/// Maps a transport-level error (no HTTP response) to a [BackendFailure].
/// The error's own text is dropped: an `http.ClientException` carries the
/// request URL, which may hold a signature.
BackendFailure s3TransportFailure(Object error, {required String host}) {
  if (error is HandshakeException || error is TlsException) {
    return BackendUnreachable(
      'Could not establish a secure connection to $host',
      null,
      kS3CodeTls,
    );
  }
  if (error is TimeoutException) {
    return BackendUnreachable('Timed out talking to $host');
  }
  if (error is SocketException || error is http.ClientException) {
    return BackendUnreachable('Could not reach $host');
  }
  return BackendUnreachable('Request to $host failed');
}
