import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/jellyfin/jellyfin_mapping.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

import 'fake_jellyfin_server.dart';

void main() {
  const sid = SourceId('jf1:u1:s1');

  test('ticks are ten million a second', () {
    expect(jellyfinSeconds(54000000000), 5400);
    expect(jellyfinSeconds(null), isNull);
  });

  test('maps collection types and skips what the player cannot show', () {
    expect(jellyfinLibraryKind('movies'), LibraryKind.movies);
    expect(jellyfinLibraryKind('tvshows'), LibraryKind.shows);
    expect(jellyfinLibraryKind('homevideos'), LibraryKind.videos);
    expect(jellyfinLibraryKind('musicvideos'), LibraryKind.videos);
    expect(jellyfinLibraryKind(null), LibraryKind.videos);
    for (final skipped in [
      'music',
      'books',
      'photos',
      'livetv',
      'playlists',
      'boxsets'
    ]) {
      expect(jellyfinLibraryKind(skipped), isNull, reason: skipped);
    }
    expect(
        jellyfinLibrary(
            sid, {'Id': 'l', 'Name': 'T', 'CollectionType': 'music'}),
        isNull);
  });

  test('a film summary carries art, year, duration and resume', () {
    final s = jellyfinSummary(
        sid, FakeJellyfinServer.movie(2, positionSeconds: 300))!;
    expect(s.ref,
        const ItemRef(sourceId: sid, kind: ItemKind.movie, externalId: 'm2'));
    expect(s.title, 'Lantern Bay 2');
    expect(s.year, 2012);
    expect(s.durationSeconds, 5400);
    expect(s.poster, const ArtworkRef('/Items/m2/Images/Primary?tag=p2'));
    expect(s.backdrop, const ArtworkRef('/Items/m2/Images/Backdrop?tag=b2'));
    expect(s.userState.progressSeconds, 300);
    expect(s.userState.watched, isFalse);
  });

  test('a zero resume position is no resume position', () {
    expect(
        jellyfinSummary(sid, FakeJellyfinServer.movie(1))!
            .userState
            .progressSeconds,
        isNull);
  });

  test('episodes carry numbers and the series name', () {
    final e = jellyfinSummary(sid, FakeJellyfinServer.episode(2))!;
    expect(e.ref.kind, ItemKind.episode);
    expect(e.index, 2);
    expect(e.parentIndex, 1);
    expect(e.subtitle, 'Saltmarsh');
    final season = jellyfinSummary(sid, FakeJellyfinServer.season)!;
    expect(season.index, 1);
    expect(season.childCount, 2);
    expect(season.parentIndex, isNull);
  });

  test('an unknown type or missing id maps to nothing', () {
    expect(jellyfinSummary(sid, {'Id': 'x', 'Type': 'Audio'}), isNull);
    expect(jellyfinSummary(sid, {'Type': 'Movie'}), isNull);
  });

  test('no image tag means no artwork', () {
    final s = jellyfinSummary(sid, {'Id': 'x', 'Type': 'Movie', 'Name': 'n'})!;
    expect(s.poster, isNull);
    expect(s.backdrop, isNull);
  });

  test('detail maps versions, streams and sidecar subtitles', () {
    final d = jellyfinDetail(sid, FakeJellyfinServer.movie(2))!;
    expect(d.overview, 'Invented film number 2.');
    expect(d.genres, ['Drama']);
    expect(d.people, ['Ilse Corran']);
    expect(d.studio, 'Northwind');
    expect(d.rating, 7.5);
    final v = d.versions.single;
    expect(v.id, 'm2');
    expect(v.container, 'mkv');
    expect(v.videoCodec, 'hevc');
    expect(v.audioCodec, 'eac3');
    expect(v.height, 1080);
    expect(v.bitrateKbps, 8000);
    expect(v.durationSeconds, 5400);
    expect(v.streamPath, '/Videos/m2/stream?static=true&mediaSourceId=m2');
    final subs = v.streams.where((s) => s.kind == MediaStreamKind.subtitle);
    expect(subs.map((s) => s.id), ['2', '3']);
    final sidecar = subs.last;
    expect(sidecar.externalPath, '/Videos/m2/m2/Subtitles/3/Stream.srt');
    expect(sidecar.codec, 'srt');
    expect(subs.first.externalPath, isNull);
    final audio = v.streams.singleWhere((s) => s.kind == MediaStreamKind.audio);
    expect(audio.isDefault, isTrue);
    expect(audio.language, 'eng');
  });

  test('a comma-separated container keeps its first name', () {
    final json = FakeJellyfinServer.movie(1);
    ((json['MediaSources'] as List).first as Map)['Container'] = 'mov,mp4,m4a';
    expect(jellyfinDetail(sid, json)!.versions.single.container, 'mov');
  });

  test('subtitle extensions', () {
    expect(jellyfinSubtitleExtension('webvtt'), 'vtt');
    expect(jellyfinSubtitleExtension('ass'), 'ass');
    expect(jellyfinSubtitleExtension('ssa'), 'ssa');
    expect(jellyfinSubtitleExtension('subrip'), 'srt');
    expect(jellyfinSubtitleExtension(null), 'srt');
  });
}
