/// Features learned about the connected server.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class ServerFeatures {
  bool heightCap = true;
}

final serverFeaturesProvider =
    Provider<ServerFeatures>((ref) => ServerFeatures());
