import 'package:player/core/sources/mydia/mydia_client.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_gql_transport.dart';

/// A [MydiaClient] over [transport], with in-memory credentials.
MydiaClient fakeMydiaClient(
  MydiaGqlTransport transport, {
  MydiaCredentials creds =
      const MydiaCredentials(instanceId: 'test', accessToken: 'access'),
  void Function()? onUnauthorized,
}) {
  var current = creds;
  return MydiaClient(
    transport: transport,
    load: () async => current,
    save: (c) async => current = c,
    onUnauthorized: onUnauthorized ?? () {},
  );
}
