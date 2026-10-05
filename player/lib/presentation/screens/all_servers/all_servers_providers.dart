/// The All servers views' state.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/merged/merged_library_reader.dart';
import '../../../domain/merged/merged_result.dart';
import '../../../domain/sources/item.dart';

final allServersReaderProvider = Provider.autoDispose<MergedLibraryReader>(
    (ref) => LiveMergedReader(ref.watch(allServersSourcesProvider)));

/// Display name per included source.
final allServersNamesProvider =
    Provider.autoDispose<Map<SourceId, String>>((ref) => {
          for (final s in ref.watch(allServersSourcesProvider))
            s.id: s.displayName,
        });

final allServersContinueWatchingProvider =
    FutureProvider.autoDispose<MergedResult<List<ItemSummary>>>(
        (ref) => ref.watch(allServersReaderProvider).continueWatching());

final allServersRecentlyAddedProvider =
    FutureProvider.autoDispose<MergedResult<List<ItemSummary>>>(
        (ref) => ref.watch(allServersReaderProvider).recentlyAdded());
