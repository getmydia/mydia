/// Native half of the pointer probe.
///
/// Always false, and never actually consulted: `InputCapabilities.touchPrimary`
/// answers from `PlatformFeatures.isMobile` off web. This exists so the
/// conditional import in `input_capabilities.dart` has a target that compiles
/// on a build with no DOM, mirroring `core/window/desktop_window_stub.dart`.
bool get coarsePointer => false;
