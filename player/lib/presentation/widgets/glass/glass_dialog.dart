import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/depth_tokens.dart';
import '../../../core/theme/liquid_glass/glass_style.dart';
import '../../../core/theme/liquid_glass/liquid_geometry.dart';
import '../../../core/theme/palette.dart';
import '../../../core/theme/surface_roles.dart';
import '../controls/press_scale.dart';
import '../glass_surface.dart';

/// An alert dialog on Liquid Glass modal glass, and a Frosted card otherwise.
///
/// [AlertDialog] paints its own Material and cannot put a backdrop behind
/// it, so the glass path rebuilds its layout (icon, title, content,
/// end-aligned actions) inside [GlassSurface.modal], as `OsdDialog` does for
/// the OSD material. [backgroundColor] and [shape] only apply off Liquid Glass.
///
/// The Frosted card is centred over the theme's scrim (`dialogTheme`'s
/// barrier colour), [frostedMaxWidth] wide unless its content needs more (up
/// to [frostedWideMaxWidth]). Callers pass actions cancel first and primary
/// last; the card stacks them full width with the primary on top, or, on a
/// card wider than 420 with exactly two actions that fit, in an end-aligned
/// row in the caller's order. The caller's last action takes the filled
/// style, or the error tint when [destructive].
///
/// Either path gives the dialog a default focus target. A route opens with no
/// focused descendant, so on a remote the first D-pad press lands nowhere.
/// After the first frame, if nothing inside the route has taken focus (a PIN
/// pad or text field that autofocuses keeps it), focus goes to the last action
/// (the primary one), or the first when [destructive] so a stray Select does
/// not confirm a delete. The actions sit under their own container node so the
/// target is found without keys on each caller's buttons: by traversal order
/// on the glass path, and on the Frosted path, whose stack reverses the visual
/// order, by identity through a node wrapping the chosen action. The
/// container is a plain
/// [Focus], not a [FocusScope]: directional traversal only searches the
/// nearest scope, so a scope here would stop UP from an action ever reaching
/// the dialog's content.
class GlassDialog extends StatefulWidget {
  const GlassDialog({
    super.key,
    this.icon,
    this.title,
    this.content,
    this.actions,
    this.backgroundColor,
    this.shape,
    this.destructive = false,
  });

  final Widget? icon;
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final Color? backgroundColor;
  final ShapeBorder? shape;

  /// Focus the first action instead of the last. Set it on confirmations that
  /// delete or remove something, where the last action is the destructive one.
  final bool destructive;

  /// Frosted card width for ordinary content.
  static const double frostedMaxWidth = 340;

  /// Frosted card width cap for content that needs more (forms, pickers).
  static const double frostedWideMaxWidth = 560;

  @override
  State<GlassDialog> createState() => _GlassDialogState();
}

class _GlassDialogState extends State<GlassDialog> {
  /// Never a stop itself: it only groups the action buttons beneath it.
  final _actionsNode = FocusNode(
    debugLabel: 'GlassDialog actions',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Frosted only: wraps the caller's action that takes the default focus,
  /// so the target is picked by identity rather than position.
  final _defaultActionNode = FocusNode(
    debugLabel: 'GlassDialog default action',
    canRequestFocus: false,
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    _scheduleDefaultFocus();
  }

  @override
  void didUpdateWidget(GlassDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A caller can swap its actions while the dialog stays up (Send logs goes
    // editing, sending, sent), which disposes the focused button and leaves
    // the route with no target. The focused-child guard keeps this a no-op
    // whenever something still holds focus.
    if (!identical(oldWidget.actions, widget.actions)) _scheduleDefaultFocus();
  }

  /// A content autofocus is only applied after the frame's callbacks, so the
  /// microtask hop lets it win before the fallback looks.
  void _scheduleDefaultFocus() {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => Future<void>.microtask(_focusDefaultAction),
    );
  }

  @override
  void dispose() {
    _actionsNode.dispose();
    _defaultActionNode.dispose();
    super.dispose();
  }

  void _focusDefaultAction() {
    if (!mounted) return;
    // The nearest scope above this state is the route's.
    final routeScope = FocusScope.of(context);
    if (routeScope.focusedChild != null) return;
    final frosted = !GlassStyle.of(context);
    final targets = (frosted ? _defaultActionNode : _actionsNode)
        .traversalDescendants
        .where((node) => node.canRequestFocus && !node.skipTraversal)
        .toList();
    if (targets.isEmpty) return;
    if (frosted) {
      targets.first.requestFocus();
    } else {
      (widget.destructive ? targets.first : targets.last).requestFocus();
    }
  }

  Widget _actionBar(List<Widget> actions) => Focus(
    focusNode: _actionsNode,
    child: OverflowBar(
      alignment: MainAxisAlignment.end,
      spacing: 8,
      children: actions,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    if (!GlassStyle.of(context)) return _frosted(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final icon = widget.icon;
    final title = widget.title;
    final content = widget.content;
    final actions = widget.actions ?? const <Widget>[];
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      child: GlassSurface.modal(
        borderRadius: BorderRadius.circular(LiquidGeometry.dialogRadius),
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: DepthTokens.liquidDialogMinWidth,
            ),
            child: IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (icon != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                      child: IconTheme.merge(
                        data: IconThemeData(color: palette.textPrimary),
                        child: icon,
                      ),
                    ),
                  if (title != null)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        icon == null ? 24 : 16,
                        24,
                        16,
                      ),
                      child: DefaultTextStyle.merge(
                        style: (textTheme.headlineSmall ?? const TextStyle())
                            .copyWith(color: palette.textPrimary),
                        textAlign: icon == null
                            ? TextAlign.start
                            : TextAlign.center,
                        child: title,
                      ),
                    ),
                  if (content != null)
                    Flexible(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          24,
                          title == null ? 24 : 0,
                          24,
                          24,
                        ),
                        child: DefaultTextStyle.merge(
                          style: (textTheme.bodyMedium ?? const TextStyle())
                              .copyWith(color: palette.textSecondary),
                          child: content,
                        ),
                      ),
                    ),
                  if (actions.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      child: _actionBar(actions),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Gap between title, content and actions, and between stacked actions.
  static const double _actionGap = 8;

  /// Card edge to actions; title and content add [textInset] to it.
  static const double _cardInset = 10;

  /// Light error for text on the error-tinted fill.
  static const Color _errorText = Color(0xFFFF8F8F);

  Widget _frosted(BuildContext context) {
    final palette = context.palette;
    final roles = context.surfaceRoles;
    final icon = widget.icon;
    final title = widget.title;
    final content = widget.content;
    final actions = widget.actions ?? const <Widget>[];
    final roleColor = widget.destructive ? AppColors.error : palette.primary;
    // Title and content sit 24 from the card edge, the actions 10.
    const textInset = EdgeInsets.symmetric(horizontal: 14);
    final defaultIndex = widget.destructive ? 0 : actions.length - 1;
    return Dialog(
      backgroundColor: widget.backgroundColor ?? palette.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape:
          widget.shape ??
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(roles.radiusModal),
            side: BorderSide(color: roles.hairline),
          ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          _cardInset,
          24,
          _cardInset,
          _cardInset,
        ),
        child: _FrostedBody(
          scrolling: content == null
              ? null
              : (icon == null ? 0 : 1) + (title == null ? 0 : 1),
          children: [
            if (icon != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Center(
                  child: Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: roleColor.withValues(alpha: 0.16),
                    ),
                    child: IconTheme.merge(
                      data: IconThemeData(color: roleColor, size: 22),
                      child: icon,
                    ),
                  ),
                ),
              ),
            if (title != null)
              Padding(
                padding: textInset,
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    fontFamily: kAppFontFamily,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                  child: title,
                ),
              ),
            if (content != null)
              SingleChildScrollView(
                padding: textInset.copyWith(
                  top: title == null ? 0 : _actionGap,
                ),
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    fontFamily: kAppFontFamily,
                    fontSize: 13.5,
                    height: 1.4,
                    color: palette.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                  child: content,
                ),
              ),
            if (actions.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  top: title == null && content == null ? 0 : 20,
                ),
                child: Focus(
                  focusNode: _actionsNode,
                  child: _FrostedActions(
                    children: [
                      for (var i = 0; i < actions.length; i++)
                        Focus(
                          focusNode: i == defaultIndex
                              ? _defaultActionNode
                              : null,
                          canRequestFocus: false,
                          skipTraversal: true,
                          child: PressScale(
                            child: _actionTheme(
                              context,
                              primary: i == actions.length - 1,
                              child: actions[i],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Restyles a caller's button, whatever its type, as a Frosted dialog
  /// action: 44 high at the control radius, and filled (or error-tinted when
  /// [GlassDialog.destructive]) when it is the [primary] one. A style the
  /// caller set on the button itself still wins.
  Widget _actionTheme(
    BuildContext context, {
    required bool primary,
    required Widget child,
  }) {
    final roles = context.surfaceRoles;
    final destructive = widget.destructive;
    WidgetStateProperty<Color?>? enabledOnly(Color color) =>
        WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled) ? null : color,
        );
    final override = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(
        Size(0, AppTheme.primaryButtonHeight),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(roles.radiusControl),
        ),
      ),
      backgroundColor: primary
          ? enabledOnly(
              destructive
                  ? AppColors.error.withValues(alpha: 0.16)
                  : Colors.white,
            )
          : null,
      foregroundColor: primary
          ? enabledOnly(destructive ? _errorText : context.palette.background)
          : null,
    );
    return TextButtonTheme(
      data: TextButtonThemeData(
        style: override.merge(TextButtonTheme.of(context).style),
      ),
      child: FilledButtonTheme(
        data: FilledButtonThemeData(
          style: override.merge(FilledButtonTheme.of(context).style),
        ),
        child: ElevatedButtonTheme(
          data: ElevatedButtonThemeData(
            style: override.merge(ElevatedButtonTheme.of(context).style),
          ),
          child: OutlinedButtonTheme(
            data: OutlinedButtonThemeData(
              style: override.merge(OutlinedButtonTheme.of(context).style),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Sizes and stacks the Frosted card's sections (icon, title, content,
/// actions), each full width.
///
/// The width is [GlassDialog.frostedMaxWidth] for ordinary content, wider (up
/// to [GlassDialog.frostedWideMaxWidth]) only when a section cannot be
/// narrower, as a form or picker of fixed width. Text wraps rather than
/// widening the card, because its minimum intrinsic width is its longest
/// word. Only widths are measured: a [Flex] with a flexible child would ask
/// that child for intrinsic heights, which a [LayoutBuilder] in the content
/// refuses.
///
/// The [scrolling] child, the content's scroll view, takes whatever height
/// the other sections leave, so tall content scrolls and the actions stay.
class _FrostedBody extends MultiChildRenderObjectWidget {
  const _FrostedBody({required this.scrolling, required super.children});

  /// Index of the child that shrinks to fit, or null.
  final int? scrolling;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFrostedBody(scrolling);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFrostedBody renderObject,
  ) => renderObject.scrolling = scrolling;
}

class _FrostedParentData extends ContainerBoxParentData<RenderBox> {}

/// Shared child bookkeeping for the two Frosted layouts.
mixin _FrostedChildren on RenderBox
    implements
        ContainerRenderObjectMixin<RenderBox, _FrostedParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FrostedParentData> {
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FrostedParentData) {
      child.parentData = _FrostedParentData();
    }
  }

  List<RenderBox> get childList {
    final children = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      children.add(child);
      child = childAfter(child);
    }
    return children;
  }

  double widest(double Function(RenderBox child) width) =>
      childList.fold(0, (w, child) => math.max(w, width(child)));

  Size sizeChild(RenderBox child, BoxConstraints c, {required bool dry}) {
    if (dry) return child.getDryLayout(c);
    child.layout(c, parentUsesSize: true);
    return child.size;
  }

  void place(RenderBox child, Offset offset, {required bool dry}) {
    if (!dry) (child.parentData! as _FrostedParentData).offset = offset;
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _RenderFrostedBody extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FrostedParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FrostedParentData>,
        _FrostedChildren {
  _RenderFrostedBody(this._scrolling);

  int? _scrolling;
  set scrolling(int? value) {
    if (value == _scrolling) return;
    _scrolling = value;
    markNeedsLayout();
  }

  static const double _inset = 2 * _GlassDialogState._cardInset;

  /// The card's inner width for a body whose widest section needs
  /// [needed], clamped between the card widths less the card's inset.
  double _widthFor(double needed) => needed.clamp(
    GlassDialog.frostedMaxWidth - _inset,
    GlassDialog.frostedWideMaxWidth - _inset,
  );

  double _neededWidth() =>
      widest((child) => child.getMinIntrinsicWidth(double.infinity));

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final children = childList;
    final width = constraints.constrainWidth(_widthFor(_neededWidth()));
    final scrolling = _scrolling;
    final heights = List<double>.filled(children.length, 0);
    var fixed = 0.0;
    for (var i = 0; i < children.length; i++) {
      if (i == scrolling) continue;
      heights[i] = sizeChild(
        children[i],
        BoxConstraints.tightFor(width: width),
        dry: dry,
      ).height;
      fixed += heights[i];
    }
    if (scrolling != null && scrolling < children.length) {
      final room = math.max(0.0, constraints.maxHeight - fixed);
      heights[scrolling] = sizeChild(
        children[scrolling],
        BoxConstraints(minWidth: width, maxWidth: width, maxHeight: room),
        dry: dry,
      ).height;
    }
    var y = 0.0;
    for (var i = 0; i < children.length; i++) {
      place(children[i], Offset(0, y), dry: dry);
      y += heights[i];
    }
    return constraints.constrain(Size(width, y));
  }

  @override
  double computeMinIntrinsicWidth(double height) => _widthFor(_neededWidth());

  @override
  double computeMaxIntrinsicWidth(double height) => _widthFor(_neededWidth());

  double _height(double width) =>
      childList.fold(0, (h, child) => h + child.getMinIntrinsicHeight(width));

  @override
  double computeMinIntrinsicHeight(double width) => _height(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _height(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }
}

/// Lays out the Frosted actions, given in the caller's order (cancel first,
/// primary last). Stacked full width with the last on top; on a card wider
/// than [_rowMinWidth] with exactly two actions that fit side by side, in an
/// end-aligned row in the caller's order.
class _FrostedActions extends MultiChildRenderObjectWidget {
  const _FrostedActions({required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFrostedActions();
}

class _RenderFrostedActions extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FrostedParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FrostedParentData>,
        _FrostedChildren {
  static const double _gap = _GlassDialogState._actionGap;
  static const double _rowMinWidth = 420;

  bool _inRow(double width) {
    if (childCount != 2 || width <= _rowMinWidth) return false;
    final natural = childList.fold<double>(
      0,
      (sum, child) => sum + child.getMaxIntrinsicWidth(double.infinity),
    );
    return natural + _gap <= width;
  }

  /// Lays the children out (or measures them when [dry]) and returns the
  /// size; positions children only when not [dry].
  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final children = childList;
    if (children.isEmpty) return constraints.smallest;
    final width = constraints.maxWidth;
    Size sizeOf(RenderBox child, BoxConstraints c) =>
        sizeChild(child, c, dry: dry);

    if (_inRow(width)) {
      final loose = BoxConstraints(maxWidth: width);
      final sizes = [for (final child in children) sizeOf(child, loose)];
      final height = math.max(sizes[0].height, sizes[1].height);
      final primaryLeft = width - sizes[1].width;
      place(
        children[1],
        Offset(primaryLeft, (height - sizes[1].height) / 2),
        dry: dry,
      );
      place(
        children[0],
        Offset(
          primaryLeft - _gap - sizes[0].width,
          (height - sizes[0].height) / 2,
        ),
        dry: dry,
      );
      return constraints.constrain(Size(width, height));
    }
    final tight = BoxConstraints.tightFor(width: width);
    var y = 0.0;
    for (final child in children.reversed) {
      if (y > 0) y += _gap;
      final size = sizeOf(child, tight);
      place(child, Offset(0, y), dry: dry);
      y += size.height;
    }
    return constraints.constrain(Size(width, y));
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      widest((child) => child.getMinIntrinsicWidth(double.infinity));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      widest((child) => child.getMaxIntrinsicWidth(double.infinity));

  double _stackedHeight(double width) {
    final children = childList;
    if (children.isEmpty) return 0;
    return children.fold<double>(
          0,
          (h, child) => h + child.getMinIntrinsicHeight(width),
        ) +
        _gap * (children.length - 1);
  }

  @override
  double computeMinIntrinsicHeight(double width) => _stackedHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _stackedHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }
}
