/// A source whose items the test scripts, and a harness that mounts a detail
/// screen over it.
library;

import 'package:flutter/material.dart' hide Page;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is not part of the main entrypoint's exports.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../helpers/cast_test_overrides.dart';
import '../../../test_utils/mock_network_images.dart';
import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';

/// A [FakeCapableSource] that answers `item` and `children` from the test.
class ScriptedDetailSource extends FakeCapableSource {
  ScriptedDetailSource({super.id, this.detailOf, this.childrenOf});

  /// Falls back to [FakeMediaSource.item] when null.
  ItemDetail Function(ItemRef ref)? detailOf;

  /// Falls back to [FakeMediaSource.children] when null.
  List<ItemSummary> Function(ItemRef parent)? childrenOf;

  @override
  Future<ItemDetail> item(ItemRef ref) async =>
      detailOf?.call(ref) ?? await super.item(ref);

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async {
    final scripted = childrenOf;
    if (scripted == null) return super.children(parent, cursor: cursor);
    return Page(items: scripted(parent));
  }
}

/// Mounts [screen] over [sources], each answering for its own id. With
/// [routes], the screen is the router's `/` and those are the places it can
/// navigate to.
Future<void> pumpDetailScreen(
  WidgetTester tester,
  Widget screen,
  List<FakeMediaSource> sources, {
  Size size = const Size(1000, 900),
  List<Override> overrides = const [],
  List<GoRoute> routes = const [],
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await mockNetworkImages(() async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        for (final s in sources) mediaSourceProvider(s.id).overrideWithValue(s),
        sourceArtworkProvider.overrideWith((ref, key) async => null),
        ...castCapableOverrides(),
        ...overrides,
      ],
      child: routes.isEmpty
          ? MaterialApp(home: screen)
          : MaterialApp.router(
              routerConfig: GoRouter(routes: [
                GoRoute(path: '/', builder: (_, __) => screen),
                ...routes,
              ]),
            ),
    ));
    await tester.pumpAndSettle();
  });
}
