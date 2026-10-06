import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/source_error.dart';

import 'scripted_mydia_transport.dart';

void main() {
  test('records operation and variables, repeats the last response', () async {
    final t = ScriptedMydiaTransport.responses([
      {'a': 1},
      {'a': 2},
    ]);
    await t.send('query One { x }', {'v': 1});
    await t.send('mutation Two { y }', const {});
    final third = await t.send('query One { x }', const {});
    expect(t.requests.map((r) => r.operation), ['One', 'Two', 'One']);
    expect(t.requests.first.variables, {'v': 1});
    expect(t.of('One'), hasLength(2));
    expect(third, {'a': 2});
  });

  test('throws what the handler returns', () {
    final t = ScriptedMydiaTransport((_, __) => graphqlError('nope'));
    expect(
        t.send('query One { x }', const {}), throwsA(isA<SourceException>()));
  });
}
