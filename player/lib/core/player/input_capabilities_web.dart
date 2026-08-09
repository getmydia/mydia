import 'package:web/web.dart' as web;

/// Web half of the pointer probe.
///
/// `(pointer: coarse)` describes the *primary* pointer, which is what this
/// needs: a laptop with a touchscreen but a mouse reports `fine` here and
/// keeps its desktop chrome, while a phone or tablet browser reports
/// `coarse`. `(any-pointer: coarse)` would wrongly catch the former.
///
/// Memoised because `touchPrimary` is read inside `build` methods
/// (`playback_chrome.dart`), and a `matchMedia` call per frame is waste. The
/// primary pointer type cannot change for the life of a document.
final bool _coarsePointer = web.window.matchMedia('(pointer: coarse)').matches;

bool get coarsePointer => _coarsePointer;
