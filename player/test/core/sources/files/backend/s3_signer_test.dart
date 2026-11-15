import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/backend/s3_signer.dart';

void main() {
  const akid = 'AKIAIOSFODNN7EXAMPLE';
  const secret = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';
  final at = DateTime.utc(2013, 5, 24);

  S3Signer signer() => S3Signer(
        accessKeyId: akid,
        secretAccessKey: secret,
        region: 'us-east-1',
        clock: () => at,
      );

  test('signs the documented GET object request', () {
    final h = signer().sign(
      method: 'GET',
      uri: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
      headers: {'range': 'bytes=0-9'},
    );
    expect(
      h['authorization'],
      'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,'
      'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,'
      'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
    );
    expect(h['host'], 'examplebucket.s3.amazonaws.com');
    expect(h['x-amz-date'], '20130524T000000Z');
    expect(
      h['x-amz-content-sha256'],
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });

  test('presigns the documented URL', () {
    final u = signer().presign(
      method: 'GET',
      uri: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
      expires: const Duration(seconds: 86400),
    );
    expect(
      u.queryParameters['X-Amz-Signature'],
      'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404',
    );
    expect(u.queryParameters['X-Amz-SignedHeaders'], 'host');
  });

  test('s3UriEncode follows the SigV4 rules', () {
    expect(
      s3UriEncode('a b+c&d#e%f/é ~', encodeSlash: false),
      'a%20b%2Bc%26d%23e%25f/%C3%A9%20~',
    );
    expect(
      s3UriEncode('a b+c&d#e%f/é ~', encodeSlash: true),
      'a%20b%2Bc%26d%23e%25f%2F%C3%A9%20~',
    );
  });

  test('canonical path is not normalized', () {
    String sig(String path) => signer().sign(
          method: 'GET',
          uri: Uri(scheme: 'https', host: 'h.example.com', path: path),
        )['authorization']!;
    expect(sig('/a//b/'), isNot(sig('/a/b')));
    expect(
      Uri(scheme: 'https', host: 'h.example.com', path: '/a//b/').path,
      '/a//b/',
    );
  });

  test('query parameters are sorted and encoded', () {
    String sig(Map<String, String> q) => signer().sign(
          method: 'GET',
          uri: Uri(
            scheme: 'https',
            host: 'h.example.com',
            path: '/',
            queryParameters: q,
          ),
        )['authorization']!;
    final a = sig({'list-type': '2', 'prefix': 'a b/', 'delimiter': '/'});
    final b = sig({'delimiter': '/', 'prefix': 'a b/', 'list-type': '2'});
    final c = sig({'prefix': 'a b/', 'delimiter': '/', 'list-type': '2'});
    expect(a, b);
    expect(a, c);
  });

  test('payloadSha256 sets the header and changes the signature', () {
    final uri = Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt');
    const hello =
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';
    final base = signer().sign(method: 'PUT', uri: uri);
    final withBody = signer().sign(
      method: 'PUT',
      uri: uri,
      payloadSha256: hello,
    );
    expect(withBody['x-amz-content-sha256'], hello);
    expect(withBody['authorization'], isNot(base['authorization']));
  });

  String sigFor(String url) => signer().sign(
        method: 'GET',
        uri: Uri.parse(url),
      )['authorization']!;

  test('sub-delimiters in the path are signed encoded', () {
    expect(sigFor('https://h.example.com/b/a+b'),
        sigFor('https://h.example.com/b/a%2Bb'));
    expect(
      sigFor("https://h.example.com/b/a+b&c=d(e)!\$'*,;:@"),
      sigFor(
        'https://h.example.com/b/a%2Bb%26c%3Dd%28e%29%21%24%27%2A%2C%3B%3A%40',
      ),
    );
  });

  test('encoded and decoded paths sign identically', () {
    final decoded = signer().sign(
      method: 'GET',
      uri: Uri(scheme: 'https', host: 'h.example.com', path: '/b/Sp ace\u00e9'),
    )['authorization'];
    expect(sigFor('https://h.example.com/b/Sp%20ace%C3%A9'), decoded);
  });
}
