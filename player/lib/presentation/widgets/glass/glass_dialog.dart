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
import 'glass_dialog_layout.dart';

/// An alert dialog on Liquid Glass modal glass, and a Frosted card otherwise.
///
/// [AlertDialog] paints its own Material and cannot put a backdrop behind
/// it, so the glass path rebuilds its layout (icon, title, content,
/// end-aligned actions) inside [GlassSurface.modal], as `OsdDialog` does for
/// the OSD material.
///
/// The Frosted card is centred over the theme's scrim (`dialogTheme`'s
/// barrier colour), [frostedMaxWidth] wide unless its content needs more (up
/// to [frostedWideMaxWidth]). Callers pass actions cancel first and primary
/// last; the card stacks them full width with the primary on top, or, on a
/// card wider than 420 with exactly two actions that fit, in an end-aligned
/// row in the caller's order. The caller's last action takes the filled
/// style, or the error tint when [destructive]. A style set on an action
/// button itself beats that, so callers pass theirs through [liquidOnly].
/// The card ignores [backgroundColor] and [shape].
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

  /// Liquid Glass ignores it, and so does the Frosted card, which is always
  /// `surfaceHigh`.
  final Color? backgroundColor;

  /// Ignored like [backgroundColor]: the Frosted card always takes the
  /// modal radius.
  final ShapeBorder? shape;

  /// Focus the first action instead of the last. Set it on confirmations that
  /// delete or remove something, where the last action is the destructive one.
  final bool destructive;

  /// [style] under Liquid Glass, and null in Frosted, where the dialog
  /// styles its actions itself (filled primary, error tint when
  /// [destructive]). For a caller's own `styleFrom(...)` on an action.
  static ButtonStyle? liquidOnly(BuildContext context, ButtonStyle style) =>
      GlassStyle.of(context) ? style : null;

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
    List<FocusNode> focusable(FocusNode group) => group.traversalDescendants
        .where((node) => node.canRequestFocus && !node.skipTraversal)
        .toList();
    // Frosted reverses the actions visually, so its target is the wrapped
    // action itself. When that action starts disabled (a primary that waits
    // on a choice), fall back to the position pick both paths used before.
    if (!GlassStyle.of(context)) {
      final identity = focusable(_defaultActionNode);
      if (identity.isNotEmpty) {
        identity.first.requestFocus();
        return;
      }
    }
    final targets = focusable(_actionsNode);
    if (targets.isEmpty) return;
    (widget.destructive ? targets.first : targets.last).requestFocus();
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
    return Dialog(
      backgroundColor: palette.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
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
        // When the icon, title and actions alone outgrow a short viewport,
        // the card scrolls whole so every action stays reachable.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final body = _frostedBody(
              context,
              viewportHeight: constraints.maxHeight,
            );
            if (!constraints.hasBoundedHeight) return body;
            return SingleChildScrollView(primary: false, child: body);
          },
        ),
      ),
    );
  }

  Widget _frostedBody(BuildContext context, {required double viewportHeight}) {
    final palette = context.palette;
    final icon = widget.icon;
    final title = widget.title;
    final content = widget.content;
    final actions = widget.actions ?? const <Widget>[];
    final roleColor = widget.destructive ? AppColors.error : palette.primary;
    // Title and content sit 24 from the card edge, the actions 10.
    const textInset = EdgeInsets.symmetric(horizontal: 14);
    final defaultIndex = widget.destructive ? 0 : actions.length - 1;
    return FrostedDialogBody(
      viewportHeight: viewportHeight,
      minWidth: GlassDialog.frostedMaxWidth - 2 * _cardInset,
      maxWidth: GlassDialog.frostedWideMaxWidth - 2 * _cardInset,
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
            padding: textInset.copyWith(top: title == null ? 0 : _actionGap),
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
              child: FrostedDialogActions(
                gap: _actionGap,
                // The card, not the action row, is what must pass 420.
                rowMinWidth: 420 - 2 * _cardInset,
                children: [
                  for (var i = 0; i < actions.length; i++)
                    Focus(
                      focusNode: i == defaultIndex ? _defaultActionNode : null,
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
