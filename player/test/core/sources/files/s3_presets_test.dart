import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/backend/s3_backend.dart';
import 'package:player/core/sources/files/s3_presets.dart';
import 'package:player/l10n/gen/app_localizations_en.dart';

void main() {
  group('endpointFor', () {
    test('AWS names the region in the host', () {
      expect(
        S3Preset.aws.endpointFor(region: 'eu-west-1'),
        Uri.parse('https://s3.eu-west-1.amazonaws.com'),
      );
      expect(
        S3Preset.aws.endpointFor(),
        Uri.parse('https://s3.us-east-1.amazonaws.com'),
      );
    });

    test('Backblaze B2 needs a region', () {
      expect(
        S3Preset.backblazeB2.endpointFor(region: 'us-west-004'),
        Uri.parse('https://s3.us-west-004.backblazeb2.com'),
      );
      expect(S3Preset.backblazeB2.endpointFor(), isNull);
    });

    test('Cloudflare R2 names the account', () {
      expect(
        S3Preset.cloudflareR2.endpointFor(accountId: 'abc'),
        Uri.parse('https://abc.r2.cloudflarestorage.com'),
      );
      expect(S3Preset.cloudflareR2.endpointFor(), isNull);
    });

    test('Wasabi names the region in the host', () {
      expect(
        S3Preset.wasabi.endpointFor(region: 'eu-central-1'),
        Uri.parse('https://s3.eu-central-1.wasabisys.com'),
      );
      expect(
        S3Preset.wasabi.endpointFor(),
        Uri.parse('https://s3.us-east-1.wasabisys.com'),
      );
    });

    test('other has no template', () {
      expect(S3Preset.other.endpointFor(region: 'x', accountId: 'y'), isNull);
    });

    test('a region that is not a host label gives no endpoint', () {
      expect(S3Preset.aws.endpointFor(region: 'eu/west'), isNull);
      expect(S3Preset.cloudflareR2.endpointFor(accountId: 'a.b'), isNull);
    });
  });

  test('each preset has its region, style and fields', () {
    expect(
      {
        for (final p in S3Preset.values)
          p: (
            p.defaultRegion,
            p.defaultStyle,
            p.needsRegion,
            p.needsAccountId,
            p.needsEndpoint,
          ),
      },
      {
        S3Preset.aws: ('us-east-1', S3Style.vhost, true, false, false),
        S3Preset.backblazeB2: (null, S3Style.path, true, false, false),
        S3Preset.cloudflareR2: ('auto', S3Style.path, false, true, false),
        S3Preset.wasabi: ('us-east-1', S3Style.path, true, false, false),
        S3Preset.other: ('us-east-1', S3Style.path, true, false, true),
      },
    );
  });

  test('labels are brand names, other is translated', () {
    final l10n = AppLocalizationsEn();
    expect(S3Preset.values.map((p) => p.label(l10n)), [
      'Amazon S3',
      'Backblaze B2',
      'Cloudflare R2',
      'Wasabi',
      'Other or self-hosted',
    ]);
  });

  group('parseS3Endpoint', () {
    test('no scheme means https', () {
      expect(
        parseS3Endpoint('minio.lan:9000'),
        Uri.parse('https://minio.lan:9000'),
      );
    });

    test('trims and keeps http', () {
      expect(
        parseS3Endpoint(' http://10.0.0.5:9000 '),
        Uri.parse('http://10.0.0.5:9000'),
      );
    });

    test('a trailing slash is the root', () {
      expect(
        parseS3Endpoint('https://s3.example.test/'),
        Uri.parse('https://s3.example.test'),
      );
    });

    test('refuses other schemes, paths and empty hosts', () {
      expect(parseS3Endpoint('ftp://x'), isNull);
      expect(parseS3Endpoint('https://h/path'), isNull);
      expect(parseS3Endpoint(''), isNull);
      expect(parseS3Endpoint('https://'), isNull);
      expect(parseS3Endpoint('https://h?x=1'), isNull);
    });
  });
}
