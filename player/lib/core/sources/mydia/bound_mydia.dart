/// The one Mydia instance the legacy screens and services serve until stage 2.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/sources/source_error.dart';
import '../source.dart';
import '../sources_providers.dart';
import '../store/source_records.dart';
import 'mydia_client.dart';
import 'mydia_credentials.dart';
import 'mydia_source.dart';

/// The account id the startup migration made of the legacy sign-in, if any.
final legacyInstanceIdProvider = FutureProvider<String?>((ref) async {
  final store = await ref.watch(sourceStoreProvider.future);
  return store.legacyInstanceId();
});

/// The instance the legacy screens and services serve: the migrated legacy
/// account while it exists, else the first Mydia account added.
final boundMydiaProvider = Provider<MydiaSource?>((ref) {
  final snapshot = ref.watch(sourceRecordsProvider).value;
  if (snapshot == null) return null;
  // Binding before the marker loads would pick the first account and then
  // switch, resetting the GraphQL cache on every cold start.
  final marker = ref.watch(legacyInstanceIdProvider);
  if (!marker.hasValue && !marker.hasError) return null;
  final legacy = marker.value;
  final mydia = [
    for (final r in snapshot.accounts)
      if (r.account.kind == SourceKind.mydia) r,
  ]..sort((a, b) => a.addedAtMs.compareTo(b.addedAtMs));
  if (mydia.isEmpty) return null;
  final bound =
      mydia.where((r) => r.account.id == legacy).firstOrNull ?? mydia.first;
  final source = ref.watch(mediaSourceProvider(mydiaSourceIdOf(bound)));
  return source is MydiaSource ? source : null;
});

final boundMydiaClientProvider =
    Provider<MydiaClient?>((ref) => ref.watch(boundMydiaProvider)?.client);

/// The bound client once the stored sources and the migrated instance id have
/// loaded, for startup code that must not conclude "none bound" too early.
/// Errors when no Mydia server is bound.
final asyncBoundMydiaClientProvider = FutureProvider<MydiaClient>((ref) async {
  await ref.watch(sourceRecordsProvider.future);
  await ref.watch(legacyInstanceIdProvider.future);
  final client = ref.watch(boundMydiaClientProvider);
  if (client == null) throw StateError('No Mydia server');
  return client;
});

/// The id of the bound account, which stays the same across its token
/// refreshes. Null with none bound.
final boundAccountIdProvider = Provider<String?>(
    (ref) => ref.watch(boundMydiaProvider.select((m) => m?.source.account.id)));

/// The bound instance's credentials, or null with none bound or readable.
final boundMydiaCredentialsProvider =
    FutureProvider<MydiaCredentials?>((ref) async {
  final client = ref.watch(boundMydiaClientProvider);
  if (client == null) return null;
  try {
    return await client.credentials();
  } on SourceException {
    return null;
  }
});

/// The id of the bound instance, which the legacy screens and services
/// address as their one Mydia server. Null with none bound.
final boundSourceIdProvider = Provider<SourceId?>(
    (ref) => ref.watch(boundMydiaProvider.select((m) => m?.source.id)));
