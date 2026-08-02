/// Stub implementation for platforms with no movable OS window (web).
library;

/// No-op: there is no window to prepare.
Future<void> initWindowDrag() async {}

/// No-op: there is no window to drag.
void startWindowDrag() {}
