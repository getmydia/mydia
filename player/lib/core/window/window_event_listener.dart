/// The window events this module reacts to.
///
/// Our own, rather than nativeapi's `WindowEvent` stream, so the controllers
/// stay free of FFI types and their tests can drive them by calling these
/// methods directly. `NativeWindowHost` translates nativeapi's events into
/// these calls. Every method defaults to a no-op.
mixin WindowEventListener {
  /// The window's size changed. nativeapi reports one event per change on
  /// every platform, Linux included.
  void onWindowResize() {}

  /// The window moved.
  void onWindowMove() {}

  void onWindowMaximize() {}

  /// The window left the maximized state. A restore from minimized never
  /// reports this.
  void onWindowUnmaximize() {}

  void onWindowEnterFullScreen() {}

  void onWindowLeaveFullScreen() {}

  /// Something asked the window to close. Informational: the close proceeds.
  void onWindowClose() {}
}
