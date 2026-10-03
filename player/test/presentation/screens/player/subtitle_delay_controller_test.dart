import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/subtitle_track.dart' as app_models;
import 'package:player/presentation/screens/player/session/playback_session_types.dart';
import 'package:player/presentation/screens/player/subtitle_delay_controller.dart';
import 'package:player/presentation/widgets/toast/toaster.dart';

const _server = app_models.SubtitleTrack(id: 'track-1', language: 'en');
const _other = app_models.SubtitleTrack(id: 'track-2', language: 'fr');
const _mpv = app_models.SubtitleTrack(id: 'mk_0', language: 'en');

class _Harness {
  _Harness({this.outcome = WriteOutcome.done, this.persist = true}) {
    controller = SubtitleDelayController(
      selectedTrack: () => selected,
      applyDelay: (ms) async => applied.add(ms),
      saveOffset: ({required trackRef, required offsetMs}) async {
        saved.add((trackRef, offsetMs));
        return outcome;
      },
      canPersist: () => persist,
      toast: (message, {kind = ToastKind.info}) => toasts.add((message, kind)),
      mounted: () => true,
      onChanged: () => changes++,
    );
  }

  final WriteOutcome outcome;
  final bool persist;
  late final SubtitleDelayController controller;
  app_models.SubtitleTrack? selected = _server;
  final applied = <int>[];
  final saved = <(String, int)>[];
  final toasts = <(String, ToastKind)>[];
  var changes = 0;
}

void main() {
  test('nudge is a no-op until offsets have loaded', () async {
    final h = _Harness();
    await h.controller.nudge(100);
    expect(h.applied, isEmpty);
    expect(h.controller.display.value, isNull);
  });

  test('setOffsets catches the baked offset up for a server track', () async {
    final h = _Harness();
    h.controller.setOffsets({'track-1': 300});
    await h.controller.sync();
    // Server already shifted the body by 300, so mpv gets no extra delay.
    expect(h.applied.last, 0);
    expect(h.controller.display.value, 300);
  });

  test('nudge applies immediately and shows the total', () async {
    final h = _Harness();
    h.controller.setOffsets({'track-1': 300});
    await h.controller.onTrackChanged();
    await h.controller.nudge(-100);
    expect(h.applied.last, -100);
    expect(h.controller.display.value, 200);
    expect(h.toasts, hasLength(1));
  });

  test('save keeps the effective delay constant', () async {
    final h = _Harness();
    h.controller.setOffsets({'track-1': 300});
    await h.controller.onTrackChanged();
    await h.controller.nudge(-100);
    final before = h.applied.last;
    await h.controller.save();
    expect(h.saved.single, ('track-1', 200));
    expect(h.applied.last, before);
    expect(h.controller.display.value, 200);
    expect(h.toasts.last.$2, ToastKind.success);
  });

  test('a save for a track no longer selected keeps the live nudge', () async {
    final h = _Harness();
    h.controller.setOffsets({'track-1': 0, 'track-2': 0});
    await h.controller.onTrackChanged();
    await h.controller.nudge(100);
    // The viewer switches tracks while the save is in flight.
    final saving = h.controller.save();
    h.selected = _other;
    await saving;
    expect(h.saved.single, ('track-1', 100));
    // Back on track-1: the stored offset absorbed 100, and the live nudge
    // of 100 was not reset, so the display reads 200.
    h.selected = _server;
    await h.controller.sync();
    expect(h.controller.display.value, 200);
  });

  test('refuses to persist an mpv-native track', () async {
    final h = _Harness()..selected = _mpv;
    h.controller.setOffsets({});
    await h.controller.onTrackChanged();
    await h.controller.nudge(100);
    await h.controller.save();
    expect(h.saved, isEmpty);
  });

  test('refuses to persist when the screen cannot write', () async {
    final h = _Harness(persist: false);
    h.controller.setOffsets({'track-1': 0});
    await h.controller.nudge(100);
    await h.controller.save();
    expect(h.saved, isEmpty);
  });

  test('a failed write toasts an error', () async {
    final h = _Harness(outcome: WriteOutcome.failed);
    h.controller.setOffsets({'track-1': 0});
    await h.controller.nudge(100);
    await h.controller.save();
    expect(h.toasts.last.$2, ToastKind.error);
  });

  test('resetNudge returns to the stored offset', () async {
    final h = _Harness();
    h.controller.setOffsets({'track-1': 300});
    await h.controller.onTrackChanged();
    await h.controller.nudge(200);
    await h.controller.resetNudge();
    expect(h.controller.display.value, 300);
  });

  test('clear forgets offsets and the loaded flag', () async {
    final h = _Harness();
    h.controller.setOffsets({'track-1': 300});
    h.controller.clear();
    await h.controller.nudge(100);
    expect(h.applied, isEmpty);
  });
}
