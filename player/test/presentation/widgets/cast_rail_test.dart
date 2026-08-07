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
}
