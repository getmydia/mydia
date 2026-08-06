import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/detail_action_row.dart';

Widget _host(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  testWidgets('tapping watched calls onToggleWatched', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_host(DetailActionRow(
      watched: false,
      onToggleWatched: () => tapped = true,
      isFavorite: false,
      onToggleFavorite: () {},
      onDownload: () {},
      trailerUrl: null,
    )));

    await tester.tap(find.byIcon(Icons.check_circle_outline_rounded));
    expect(tapped, isTrue);
  });

  testWidgets('tapping favorite calls onToggleFavorite', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_host(DetailActionRow(
      watched: false,
      onToggleWatched: () {},
      isFavorite: false,
      onToggleFavorite: () => tapped = true,
      onDownload: () {},
      trailerUrl: null,
    )));

    await tester.tap(find.byIcon(Icons.favorite_border_rounded));
    expect(tapped, isTrue);
  });

  testWidgets('trailer button is absent when trailerUrl is null',
      (tester) async {
    await tester.pumpWidget(_host(DetailActionRow(
      watched: false,
      onToggleWatched: () {},
      isFavorite: false,
      onToggleFavorite: () {},
      onDownload: () {},
      trailerUrl: null,
    )));

    expect(find.text('Trailer'), findsNothing);
  });

  testWidgets('trailer button is present when trailerUrl is set',
      (tester) async {
    await tester.pumpWidget(_host(DetailActionRow(
      watched: false,
      onToggleWatched: () {},
      isFavorite: false,
      onToggleFavorite: () {},
      onDownload: () {},
      trailerUrl: 'https://www.youtube.com/watch?v=abc123',
    )));

    expect(find.text('Trailer'), findsOneWidget);
  });
}
