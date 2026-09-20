// Runs only under `flutter test --platform chrome`: this is text track state
// on a real `<video>`, and subtitle_cues_web.dart is not reachable from a VM
// test run at all.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/subtitle_cues_web.dart';
import 'package:web/web.dart' as web;

/// A `<video>` carrying [count] tracks, the way media_kit leaves one after
/// that many subtitle picks: appended in order, none of them showing.
web.HTMLVideoElement _videoWithTracks(int count) {
  final video = web.HTMLVideoElement();
  for (var i = 0; i < count; i++) {
    final track = web.HTMLTrackElement()
      ..kind = 'subtitles'
      ..label = 'track $i'
      ..src = 'data:text/vtt,WEBVTT%0A%0A00:00.000%20--%3E%2000:01.000%0A$i';
    video.appendChild(track);
  }
  return video;
}

List<String> _modes(web.HTMLVideoElement video) => [
      for (var i = 0; i < video.textTracks.length; i++) video.textTracks[i].mode
    ];

void main() {
  test('shows the track that was added last', () {
    // The newest is the pick the viewer just made; everything before it is a
    // spent pick media_kit left attached.
    final video = _videoWithTracks(3);

    applyCueVisibility(video, enabled: true);

    expect(_modes(video), ['disabled', 'disabled', 'showing']);
  });

  test('turning subtitles off leaves nothing drawing', () {
    // media_kit does nothing at all for SubtitleTrack.no() on web, so this
    // half is the only thing that can turn them back off.
    final video = _videoWithTracks(2);
    applyCueVisibility(video, enabled: true);

    applyCueVisibility(video, enabled: false);

    expect(_modes(video), ['disabled', 'disabled']);
  });

  test('a second pick moves the showing track, never adds one', () {
    final video = _videoWithTracks(1);
    applyCueVisibility(video, enabled: true);
    expect(_modes(video), ['showing']);

    // media_kit appends rather than replaces, including for a re-pick.
    final another = web.HTMLTrackElement()
      ..kind = 'subtitles'
      ..src = 'data:text/vtt,WEBVTT';
    video.appendChild(another);
    applyCueVisibility(video, enabled: true);

    expect(_modes(video), ['disabled', 'showing']);
  });

  test('a video with no tracks is left alone', () {
    final video = _videoWithTracks(0);

    applyCueVisibility(video, enabled: true);
    applyCueVisibility(video, enabled: false);

    expect(video.textTracks.length, 0);
  });
}
