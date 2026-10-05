/// What a merged read returns, and which servers it could not include.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/source.dart';

@immutable
class MergedResult<T> {
  const MergedResult(this.value,
      {this.unavailable = const [], this.skipped = const []});

  final T value;

  /// Failed or timed out this time.
  final List<SourceId> unavailable;

  /// Lack the capability or the chosen sort.
  final List<SourceId> skipped;
}
