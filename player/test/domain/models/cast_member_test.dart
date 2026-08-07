import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/cast_member.dart';

void main() {
  group('CastMember.fromJson', () {
    test('parses a full cast member', () {
      final member = CastMember.fromJson({
        'name': 'Keanu Reeves',
        'character': 'Neo',
        'profileUrl': 'https://image.tmdb.org/t/p/w185/abc.jpg',
      });

      expect(member.name, 'Keanu Reeves');
      expect(member.character, 'Neo');
      expect(member.profileUrl, 'https://image.tmdb.org/t/p/w185/abc.jpg');
    });

    test('character and profileUrl are nullable', () {
      final member = CastMember.fromJson({
        'name': 'Keanu Reeves',
        'character': null,
        'profileUrl': null,
      });

      expect(member.character, isNull);
      expect(member.profileUrl, isNull);
    });
  });
}
