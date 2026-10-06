/// The local media proxy, pointed at a paired guest.
library;

import '../../p2p/local_proxy_service.dart';
import 'mydia_credentials.dart';

/// The local proxy's base URL for a paired guest, starting the proxy for
/// [owner] if it is not already serving [target]. A repeat start re-targets
/// with the credentials as they are now, which picks up a refreshed token.
Future<String> guestProxyBase(
  LocalProxyService proxy,
  MydiaCredentials credentials, {
  required Object owner,
  required String target,
}) async {
  await proxy.start(
    owner: owner,
    targetPeer: credentials.nodeAddr!,
    authToken: credentials.accessToken,
    target: target,
  );
  return proxy.targetBaseUrl(target);
}
