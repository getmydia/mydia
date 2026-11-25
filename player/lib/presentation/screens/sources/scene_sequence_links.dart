/// The one gate every listing passes a scene's place through on its way to
/// the item and player routes.
library;

import '../../../core/sources/capabilities.dart';
import '../../../core/sources/media_source.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/playback_sequence.dart';

/// The listing [item] was opened from, built by [build], when [source] can
/// name a scene's neighbours and [item] is a scene. Null otherwise, so every
/// other item keeps the location it has always had.
PlaybackSequence? sceneSequenceFor(
  MediaSource? source,
  ItemSummary item,
  PlaybackSequence Function() build,
) => item.ref.kind == ItemKind.video && source?.as<SceneSequence>() != null
    ? build()
    : null;
