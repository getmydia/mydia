import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';
import 'package:player/presentation/widgets/video_controls/playback_title.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  const route = 'The Lantern Coast S2E4';

  PlaybackTitle resolve({bool isEpisode = true, PlaybackDetail? detail}) =>
      PlaybackTitle.resolve(
        routeTitle: route,
        isEpisode: isEpisode,
        detail: detail,
        l10n: l10n,
      );

  PlaybackDetail episode({
    String? showTitle = 'The Lantern Coast',
    int? season = 2,
    int? number = 4,
    String? name = 'Low Tide',
  }) => PlaybackDetail(
    showTitle: showTitle,
    seasonNumber: season,
    episodeNumber: number,
    episodeTitle: name,
  );

  test('no detail falls back to the route title alone', () {
    final t = resolve();
    expect(t.title, route);
    expect(t.kicker, isNull);
  });

  test('an episode with every part gets show title and a full kicker', () {
    final t = resolve(detail: episode());
    expect(t.title, 'The Lantern Coast');
    expect(t.kicker, 'S2, E4 · Low Tide');
  });

  test('an episode without a name keeps the code', () {
    expect(resolve(detail: episode(name: null)).kicker, 'S2, E4');
    expect(resolve(detail: episode(name: '  ')).kicker, 'S2, E4');
  });

  test('a missing number leaves only the name', () {
    expect(resolve(detail: episode(number: null)).kicker, 'Low Tide');
    expect(resolve(detail: episode(season: null)).kicker, 'Low Tide');
  });

  test('an episode without a show title keeps the route title', () {
    final t = resolve(detail: episode(showTitle: null));
    expect(t.title, route);
    expect(t.kicker, isNull);
  });

  test('a blank show title counts as missing', () {
    final t = resolve(detail: episode(showTitle: '  '));
    expect(t.title, route);
    expect(t.kicker, isNull);
  });

  test('a movie shows its year as the kicker', () {
    final t = resolve(
      isEpisode: false,
      detail: const PlaybackDetail(year: 2024),
    );
    expect(t.title, route);
    expect(t.kicker, '2024');
  });

  test('a movie without a year has no kicker', () {
    final t = resolve(isEpisode: false, detail: const PlaybackDetail());
    expect(t.title, route);
    expect(t.kicker, isNull);
  });

  test('equal titles compare equal', () {
    expect(
      const PlaybackTitle(title: 'a', kicker: 'b'),
      const PlaybackTitle(title: 'a', kicker: 'b'),
    );
    expect(
      const PlaybackTitle(title: 'a', kicker: 'b').hashCode,
      const PlaybackTitle(title: 'a', kicker: 'b').hashCode,
    );
    expect(
      const PlaybackTitle(title: 'a'),
      isNot(const PlaybackTitle(title: 'a', kicker: 'b')),
    );
  });
}
