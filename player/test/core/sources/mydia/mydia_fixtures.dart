const sid = 'mguest:owner:inst-2';

Map<String, dynamic> art(String name) => {
      'posterUrl': 'https://img.example/$name-poster.jpg',
      'backdropUrl': 'https://img.example/$name-backdrop.jpg',
      'thumbnailUrl': null,
    };

Map<String, dynamic> file(String id) => {
      'id': id,
      'resolution': '1080p',
      'codec': 'hevc',
      'audioCodec': 'eac3',
      'hdrFormat': null,
      'size': 1000,
      'bitrate': 8000000,
      'directPlaySupported': true,
      'streamUrl': null,
      'directPlayUrl': null,
      'subtitles': [
        {
          'trackId': 'sub-1',
          'language': 'en',
          'title': 'English',
          'format': 'srt',
          'embedded': false,
          'deliverable': true,
          'forced': false,
          'hearingImpaired': false,
          'url': '/api/v1/subtitles/sub-1.vtt',
        }
      ],
    };

Map<String, dynamic> movie(String id,
        {bool watched = false, int position = 0}) =>
    {
      'id': id,
      'title': 'The Quiet Orchard $id',
      'originalTitle': null,
      'year': 2021,
      'overview': 'A beekeeper inherits a valley.',
      'runtime': 104,
      'genres': ['Drama'],
      'contentRating': 'PG',
      'rating': 7.4,
      'artwork': art(id),
      'progress': {
        'positionSeconds': position,
        'durationSeconds': 6240,
        'percentage': 0.0,
        'watched': watched,
        'lastWatchedAt': null,
      },
      'files': [file('f-$id')],
      'isFavorite': true,
    };

Map<String, dynamic> show(String id) => {
      'id': id,
      'title': 'Lantern Street $id',
      'originalTitle': null,
      'year': 2019,
      'overview': 'Neighbours keep a lighthouse running.',
      'genres': ['Comedy'],
      'contentRating': 'TV-14',
      'rating': 8.1,
      'seasonCount': 2,
      'artwork': art(id),
      'seasons': [
        {
          'seasonNumber': 1,
          'episodeCount': 3,
          'airedEpisodeCount': 3,
          'hasFiles': true,
          'watchStatus': {
            'watched': true,
            'percentage': 1.0,
            'unwatchedEpisodeCount': 0
          }
        },
        {
          'seasonNumber': 2,
          'episodeCount': 2,
          'airedEpisodeCount': 2,
          'hasFiles': true,
          'watchStatus': {
            'watched': false,
            'percentage': 0.0,
            'unwatchedEpisodeCount': 2
          }
        },
      ],
      'nextUp': {
        'progressState': 'next',
        'episode': {
          'id': 'e-21',
          'seasonNumber': 2,
          'episodeNumber': 1,
          'title': 'Low Tide',
          'runtime': 24,
          'files': [
            {'id': 'f-e-21'}
          ],
          'progress': null
        },
      },
      'isFavorite': false,
      'cast': [
        {
          'name': 'Ines Varga',
          'character': 'Keeper',
          'profileUrl': 'https://img.example/ines.jpg'
        },
      ],
      'trailerUrl': 'https://video.example/trailer',
      'similar': [
        {
          'id': 's-9',
          'type': 'TV_SHOW',
          'title': 'Harbour Lights',
          'year': 2018,
          'artwork': art('s-9')
        },
      ],
      'watchStatus': {
        'watched': false,
        'percentage': 0.5,
        'unwatchedEpisodeCount': 2
      },
    };

Map<String, dynamic> episode(String id, {int season = 2, int number = 1}) => {
      'id': id,
      'seasonNumber': season,
      'episodeNumber': number,
      'title': 'Low Tide',
      'overview': 'The lamp fails.',
      'airDate': '2019-04-02',
      'runtime': 24,
      'thumbnailUrl': 'https://img.example/$id.jpg',
      'hasFile': true,
      'progress': {
        'positionSeconds': 60,
        'durationSeconds': 1440,
        'percentage': 4.0,
        'watched': false,
        'lastWatchedAt': null
      },
      'files': [file('f-$id')],
      'show': {
        'id': 's-1',
        'title': 'Lantern Street s-1',
        'artwork': art('s-1')
      },
    };
