/// An [EpisodeView] on the test Mydia source, for tests of the episode rail.
library;

import 'package:player/domain/detail/detail_art.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/domain/models/progress.dart';
import 'package:player/domain/sources/item.dart';

import 'mydia_test_source.dart';

/// The ref [testEpisodeView] gives the episode with [id].
ItemRef testEpisodeRef(String id) => testMydiaRef(ItemKind.episode, id);

EpisodeView testEpisodeView({
  String id = 'ep-1',
  int seasonNumber = 1,
  int episodeNumber = 1,
  String title = 'Pilot',
  String? overview,
  bool hasFile = true,
  Progress? progress,
  String? thumbnailUrl,
  List<MediaFile> files = const [],
  Set<DetailFeature> features = const {
    DetailFeature.watched,
    DetailFeature.download,
  },
}) =>
    EpisodeView(
      target: SourceTarget(testEpisodeRef(id)),
      showTitle: 'Test Show',
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      title: title,
      overview: overview,
      still: thumbnailUrl == null ? null : UrlArt(thumbnailUrl),
      progress: progress,
      files: files,
      hasFile: hasFile,
      features: features,
    );
