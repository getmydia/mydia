import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/startup/startup_timeline.dart';

void main() {
  test('records the first time a mark is hit, in order', () {
    var now = 0;
    final t = StartupTimeline('startup', elapsedMs: () => now);
    now = 12;
    t.mark('rust_init');
    now = 40;
    t.mark('hive');
    now = 99;
    t.mark('rust_init'); // repeat is ignored
    expect(t.marks, {'rust_init': 12, 'hive': 40});
    expect(t.summary(), 'startup: rust_init=12 hive=40');
  });

  test('logOnce logs a single summary line', () {
    var now = 5;
    final t = StartupTimeline('playback', elapsedMs: () => now)..mark('opened');
    final lines = <String>[];
    t.logOnce(lines.add);
    now = 9;
    t.mark('first_frame');
    t.logOnce(lines.add);
    expect(lines, ['playback: opened=5']);
  });
}
