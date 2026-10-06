/// The local media proxy, pointed at a paired Mydia server.
library;

import '../../p2p/media_proxy.dart';
import 'mydia_credentials.dart';

/// The local proxy's base URL for a paired Mydia server, starting the proxy
/// for [owner] if it is not already serving [target]. A repeat start
/// re-targets with the credentials as they are now, which picks up a
/// refreshed token.
Future<String> mydiaProxyBase(
  MediaProxy proxy,
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
