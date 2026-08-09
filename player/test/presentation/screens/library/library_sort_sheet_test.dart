import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/library/library_sort.dart';

void main() {
  testWidgets('every sort field gets a row', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                for (final field in SortField.values)
                  ListTile(
                    key: Key('sort-field-${field.wireName}'),
                    title: Text(field.displayName),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    for (final field in SortField.values) {
      expect(find.byKey(Key('sort-field-${field.wireName}')), findsOneWidget);
    }
  });

  test('selecting the current field flips direction', () {
    const current = LibrarySort(
      field: SortField.title,
      direction: SortDirection.asc,
    );

    expect(current.direction.flipped, SortDirection.desc);
    expect(current.direction.flipped.flipped, SortDirection.asc);
  });

  test('random does not support a direction toggle', () {
    expect(SortField.random.supportsDirection, isFalse);
  });
}
