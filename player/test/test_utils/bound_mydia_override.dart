/// A bound Mydia instance for widget tests that need the router, the shell or
/// the remote-control gate to see one, without any stored account or network.
library;

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:player/core/sources/media_source.dart'
    show SourceConnectionStatus;
import 'package:player/core/sources/mydia/bound_mydia.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:flutter/foundation.dart';

import '../core/sources/mydia/fake_mydia_client.dart';
import '../core/sources/mydia/fake_mydia_transport.dart';
import 'mydia_test_source.dart';

/// Binds [testMydiaSource] and reports the stored sources as loaded.
List<Override> boundMydiaOverrides({
  ValueListenable<SourceConnectionStatus>? status,
}) =>
    [
      sourcesLoadingProvider.overrideWithValue(false),
      hasMydiaProvider.overrideWithValue(true),
      boundMydiaProvider.overrideWithValue(MydiaSource(
        source: testMydiaSource,
        client: fakeMydiaClient(FakeMydiaTransport()),
        status: status,
      )),
    ];
