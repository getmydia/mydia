/// Home Mydia as a full [MediaSource], read only by the All servers views.
/// Home's own screens keep their controllers; `mediaSourceProvider` keeps
/// the stub for `SourceId.legacyMydia`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../graphql/graphql_provider.dart';
import '../../p2p/local_proxy_service.dart';
import '../media_source.dart';
import '../source.dart';
import '../sources_providers.dart';
import 'home_mydia_transport.dart';
import 'mydia_guest_client.dart';
import 'mydia_guest_credentials.dart';
import 'mydia_guest_source.dart';

final homeMydiaBrowseSourceProvider = Provider<MediaSource?>((ref) {
  if (!ref.watch(mydiaPresentProvider)) return null;
  final client = MydiaGuestClient(
    transport:
        HomeMydiaTransport(() => ref.read(asyncGraphqlClientProvider.future)),
    // Home's client holds the real token; these are never sent.
    load: () async =>
        const MydiaGuestCredentials(instanceId: 'home', accessToken: ''),
    save: (_) async {},
    // Home sign-in failures surface through home's own auth state.
    onUnauthorized: () {},
  );
  // Downloads of home items go through `mediaSourceProvider`'s home source,
  // never this one, so its proxy is never taken.
  final source = MydiaGuestSource(
    source: Source.legacyMydia(),
    client: client,
    proxy: () => ref.read(localProxyServiceProvider),
  );
  ref.onDispose(source.dispose);
  return source;
});
