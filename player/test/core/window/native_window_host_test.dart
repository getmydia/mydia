import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/native_window_host.dart';
import 'package:player/core/window/window_event_listener.dart';
import 'package:window_manager/window_manager.dart';

class _Recorder with WindowEventListener {
  final List<String> calls = [];

  @override
  void onWindowResize() => calls.add('resize');

  @override
  void onWindowMove() => calls.add('move');

  @override
  void onWindowMaximize() => calls.add('maximize');

  @override
  void onWindowUnmaximize() => calls.add('unmaximize');

  @override
  void onWindowEnterFullScreen() => calls.add('enterFullScreen');

  @override
  void onWindowLeaveFullScreen() => calls.add('leaveFullScreen');

  @override
  void onWindowClose() => calls.add('close');
}

void main() {
  const id = 1;
  late NativeWindowHost host;
  late _Recorder recorder;

  setUp(() {
    host = NativeWindowHost.detached();
    recorder = _Recorder();
    // No native window: the listener is kept, and addListener swallows the
    // failed lookup.
    host.addListener(recorder);
  });

  test('resize, move and close pass straight through', () {
    host
      ..handleEvent(
        WindowResizedEvent(windowId: id, newSize: const Size(1, 1).toNative()),
      )
      ..handleEvent(
        WindowMovedEvent(windowId: id, newPosition: Offset.zero.toNative()),
      )
      ..handleEvent(
        WindowCloseRequestedEvent(
          windowId: id,
          request: EventRequest.borrowed(0),
        ),
      );

    expect(recorder.calls, ['resize', 'move', 'close']);
  });

  test('a restore after maximize is an unmaximize', () {
    host
      ..handleEvent(const WindowMaximizedEvent(windowId: id))
      ..handleEvent(const WindowRestoredEvent(windowId: id));

    expect(recorder.calls, ['maximize', 'unmaximize']);
  });

  test('a restore from minimized is not an unmaximize', () {
    host
      ..handleEvent(const WindowMinimizedEvent(windowId: id))
      ..handleEvent(const WindowRestoredEvent(windowId: id));

    expect(recorder.calls, isEmpty);
  });

  test('a restore from minimized back to maximized reports nothing', () {
    host
      ..handleEvent(const WindowMaximizedEvent(windowId: id))
      ..handleEvent(const WindowMinimizedEvent(windowId: id))
      ..handleEvent(const WindowRestoredEvent(windowId: id));

    // The detached host reads no window, so it cannot tell the window came
    // back maximized; what matters is that leaving minimized is no unmaximize.
    expect(recorder.calls, ['maximize']);
  });

  test('fullscreen changes are reported once each', () {
    host
      ..handleEvent(const WindowEnteredFullScreenEvent(windowId: id))
      ..handleEvent(const WindowEnteredFullScreenEvent(windowId: id))
      ..handleEvent(const WindowExitedFullScreenEvent(windowId: id))
      ..handleEvent(const WindowExitedFullScreenEvent(windowId: id));

    expect(recorder.calls, ['enterFullScreen', 'leaveFullScreen']);
  });

  test('a removed listener hears nothing more', () {
    host
      ..removeListener(recorder)
      ..handleEvent(const WindowMaximizedEvent(windowId: id));

    expect(recorder.calls, isEmpty);
  });

  test('a listener that throws does not stop the others', () {
    final second = _Recorder();
    host
      ..addListener(_Throwing())
      ..addListener(second)
      ..handleEvent(const WindowMaximizedEvent(windowId: id));

    expect(recorder.calls, ['maximize']);
    expect(second.calls, ['maximize']);
  });
}

class _Throwing with WindowEventListener {
  @override
  void onWindowMaximize() => throw StateError('boom');
}
