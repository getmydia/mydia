import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/cast_member.dart';
import 'package:player/presentation/widgets/cast_rail.dart';

Widget _host(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  testWidgets('renders nothing when there is no cast', (tester) async {
    await tester.pumpWidget(_host(const CastRail(members: [])));

    expect(find.byType(CastRail), findsOneWidget);
    expect(find.text('Cast'), findsNothing);
  });

  testWidgets('renders a card per cast member with name and character',
      (tester) async {
    await tester.pumpWidget(_host(const CastRail(
      members: [
        CastMember(name: 'Ana Bergström', character: 'Kira Solt'),
        CastMember(name: 'Marcus Ijeoma', character: 'Deck Chief Reyes'),
      ],
    )));

    expect(find.text('Cast'), findsOneWidget);
    expect(find.text('Ana Bergström'), findsOneWidget);
    expect(find.text('Kira Solt'), findsOneWidget);
    expect(find.text('Marcus Ijeoma'), findsOneWidget);
  });

  testWidgets('falls back to a person icon when there is no profile photo',
      (tester) async {
    await tester.pumpWidget(_host(const CastRail(
      members: [CastMember(name: 'Ana Bergström')],
    )));

    expect(find.byIcon(Icons.person_rounded), findsOneWidget);
  });

  testWidgets('a vertical wheel scrolls the cast rail', (tester) async {
    await tester.pumpWidget(_host(CastRail(
      members: List.generate(
        20,
        (i) => CastMember(name: 'Actor $i', character: 'Role $i'),
      ),
    )));

    final position = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .map((s) => s.position)
        .firstWhere((p) => p.axis == Axis.horizontal);

    // Hovers over the ListView itself, not the CastRail widget: CastRail's
    // Column defaults to MainAxisSize.max, and this test's `_host` makes it
    // the sole, unconstrained-height child of a Scaffold body, so its render
    // box stretches to the full 600px test surface even though the rail only
    // paints its top ~166px. getCenter(find.byType(CastRail)) then lands in
    // that empty lower region and never reaches the wheel listener. In the
    // real app CastRail sits inside a scrolling page body, where its box
    // hugs its content and this divergence does not occur.
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(tester.getCenter(find.byType(ListView)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
    await tester.pumpAndSettle();

    expect(position.pixels, greaterThan(0));
  });
}
