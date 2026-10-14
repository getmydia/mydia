import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/breakpoints.dart';

void main() {
  test('content inset clears the rail and its gap', () {
    expect(Breakpoints.railContentInset(pinned: false), 16 + 72 + 24);
    expect(Breakpoints.railContentInset(pinned: true), 16 + 272 + 24);
  });

  for (final (width, expected) in [
    (599.0, false),
    (600.0, true),
    (1280.0, true),
  ]) {
    testWidgets('showsRail at $width is $expected', (tester) async {
      late bool shows;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: Size(width, 800)),
          child: Builder(
            builder: (c) {
              shows = Breakpoints.showsRail(c);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(shows, expected);
    });
  }
}
