import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/sources/item.dart';

/// The season shown on a show's detail page, per show. Starts on season 1.
class SelectedSeason extends Notifier<int> {
  SelectedSeason(this.show);

  final ItemRef show;

  @override
  int build() => 1;

  void select(int seasonNumber) {
    state = seasonNumber;
  }
}

final selectedSeasonProvider =
    NotifierProvider.autoDispose.family<SelectedSeason, int, ItemRef>(
  SelectedSeason.new,
);

/// The episode the hero currently describes on a show's detail page.
/// Deliberately starts at `null` rather than deriving a default from the show
/// view here: doing so would need `ref.watch`, which would make this provider
/// rebuild, resetting any explicit tap the user already made, every time the
/// show query re-resolves (e.g. after an unrelated favorite toggle
/// invalidation). `ShowDetailScreen` sets the actual default (next-unwatched
/// episode) via a post-frame callback once, the same self-correction idiom
/// `ShowSeasonSection` already uses for season selection.
class SelectedEpisode extends Notifier<String?> {
  SelectedEpisode(this.show);

  final ItemRef show;

  @override
  String? build() => null;

  void select(String episodeId) {
    state = episodeId;
  }
}

final selectedEpisodeProvider =
    NotifierProvider.autoDispose.family<SelectedEpisode, String?, ItemRef>(
  SelectedEpisode.new,
);
