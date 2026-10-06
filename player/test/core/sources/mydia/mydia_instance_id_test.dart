import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/mydia_instance_id.dart';
import 'package:player/core/sources/source.dart';

void main() {
  group('mydiaInstanceIdOfAccount', () {
    test('strips the m prefix', () {
      expect(mydiaInstanceIdOfAccount('minst-a'), 'inst-a');
    });

    test('is null for null, empty, a bare m and a non-Mydia id', () {
      expect(mydiaInstanceIdOfAccount(null), isNull);
      expect(mydiaInstanceIdOfAccount(''), isNull);
      expect(mydiaInstanceIdOfAccount('m'), isNull);
      expect(mydiaInstanceIdOfAccount('plex-1'), isNull);
    });
  });

  group('mydiaInstanceIdOfSource', () {
    test('reads the account segment of a Mydia source id', () {
      expect(
        mydiaInstanceIdOfSource(const SourceId('minst-a:owner:inst-a')),
        'inst-a',
      );
    });

    test('is null for none, a bare m and a non-Mydia source id', () {
      expect(mydiaInstanceIdOfSource(SourceId.none), isNull);
      expect(mydiaInstanceIdOfSource(const SourceId('m:owner:x')), isNull);
      expect(mydiaInstanceIdOfSource(const SourceId('pabc:u1:srv')), isNull);
    });
  });
}
