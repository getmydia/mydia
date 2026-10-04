/// Providers for the plex.tv client and Plex Home switching.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../source_factories.dart';
import '../sources_providers.dart';
import 'plex_home_switcher.dart';
import 'plex_identity.dart';
import 'plex_tv_client.dart';

final plexTvClientProvider =
    FutureProvider<PlexTvClient>((ref) async => PlexTvClient(
          http: ref.watch(sourceHttpProvider),
          identity: await ref.watch(plexIdentityProvider.future),
        ));

final plexHomeSwitcherProvider =
    FutureProvider<PlexHomeSwitcher>((ref) async => PlexHomeSwitcher(
          tv: await ref.watch(plexTvClientProvider.future),
          secrets: ref.watch(sourceSecretsProvider),
          records: ref.watch(sourceRecordsProvider.notifier),
        ));
