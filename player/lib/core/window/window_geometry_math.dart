import 'dart:math' as math;
import 'dart:ui';

/// One display's usable area, in global logical coordinates — the screen minus
/// menu bars, docks, and taskbars.
class WorkArea {
  final Rect bounds;
  final bool isPrimary;

  const WorkArea({required this.bounds, required this.isPrimary});
}

/// How tall a window's grabbable title bar is assumed to be.
const double kTitleBarStripHeight = 40;

/// How much of that strip must be on-screen before we call the window
/// grabbable. Anything smaller is a target the user cannot realistically hit.
const double _kMinGrabWidth = 100;
const double _kMinGrabHeight = 20;

const Size kMinWindowSize = Size(720, 480);
const Size kDefaultWindowSize = Size(1280, 800);

/// Whether enough of [window]'s title bar overlaps some display to drag it.
///
/// Deliberately *not* a whole-rect intersection test. A window whose title bar
/// sits above the menu bar overlaps its display almost entirely and is still
/// unrecoverable, because there is nothing left to grab.
bool isTitleBarReachable(Rect window, List<WorkArea> areas) {
  final strip = Rect.fromLTWH(
    window.left,
    window.top,
    window.width,
    math.min(kTitleBarStripHeight, window.height),
  );

  for (final area in areas) {
    final overlap = strip.intersect(area.bounds);
    if (overlap.width >= _kMinGrabWidth && overlap.height >= _kMinGrabHeight) {
      return true;
    }
  }
  return false;
}

/// The display flagged primary, else the first one, else null.
WorkArea? primaryArea(List<WorkArea> areas) {
  if (areas.isEmpty) return null;
  for (final area in areas) {
    if (area.isPrimary) return area;
  }
  return areas.first;
}

/// [saved] unchanged when it is still reachable; otherwise the same size,
/// clamped to the primary work area and centered on it.
///
/// Returns null when there are no displays to reason about, which the caller
/// treats as "leave the window alone and let the OS decide".
Rect? recoverOffscreenWindow(Rect saved, List<WorkArea> areas) {
  if (areas.isEmpty) return null;
  if (isTitleBarReachable(saved, areas)) return saved;

  final area = primaryArea(areas)!.bounds;
  return _centerIn(
    Size(
      math.min(saved.width, area.width),
      math.min(saved.height, area.height),
    ),
    area,
  );
}

/// [kDefaultWindowSize] centered on the primary display, for a first launch.
Rect? defaultWindowRect(List<WorkArea> areas) {
  final area = primaryArea(areas);
  if (area == null) return null;

  return _centerIn(
    Size(
      math.min(kDefaultWindowSize.width, area.bounds.width),
      math.min(kDefaultWindowSize.height, area.bounds.height),
    ),
    area.bounds,
  );
}

Rect _centerIn(Size size, Rect area) => Rect.fromLTWH(
      area.left + (area.width - size.width) / 2,
      area.top + (area.height - size.height) / 2,
      size.width,
      size.height,
    );
