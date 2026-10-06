import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/item.dart';

void main() {
  test('unwatchedCount round-trips and defaults to null', () {
    const s = UserState(watched: false, unwatchedCount: 3);
    expect(UserState.fromJson(s.toJson()).unwatchedCount, 3);
    expect(UserState.fromJson(const {'watched': true}).unwatchedCount, isNull);
  });
}
