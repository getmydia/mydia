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

/// The display holding [window]'s centre, else the primary, else null.
WorkArea? areaContaining(Rect window, List<WorkArea> areas) {
  if (areas.isEmpty) return null;
  final centre = window.center;
  for (final area in areas) {
    if (area.bounds.contains(centre)) return area;
  }
  return primaryArea(areas);
}

/// Reshapes [current] to [aspect], keeping its width and its centre point.
///
/// The centre is held rather than the top-left so the window grows and shrinks
/// symmetrically instead of sliding down and to the right off the bottom of
/// the screen.
///
/// [minSize] wins over the aspect: a window that would have to go below
/// 720x480 to match a 2.39:1 film letterboxes instead of becoming unusable.
Rect fitToAspect({
  required Rect current,
  required double aspect,
  required Rect workArea,
  Size minSize = kMinWindowSize,
}) {
  var width = current.width;
  var height = width / aspect;

  // Fit inside the display before applying the floor, so the floor is the last
  // word and cannot be undone by a later clamp.
  if (height > workArea.height) {
    height = workArea.height;
    width = height * aspect;
  }
  if (width > workArea.width) {
    width = workArea.width;
    height = width / aspect;
  }

  width = math.max(width, minSize.width);
  height = math.max(height, minSize.height);

  final centre = current.center;
  var left = centre.dx - width / 2;
  var top = centre.dy - height / 2;

  // Slide, never resize: the aspect computed above must survive this step.
  left = left.clamp(
    workArea.left,
    math.max(workArea.left, workArea.right - width),
  );
  top = top.clamp(
    workArea.top,
    math.max(workArea.top, workArea.bottom - height),
  );

  return Rect.fromLTWH(left, top, width, height);
}
