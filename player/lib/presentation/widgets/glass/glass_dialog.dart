import 'package:flutter/material.dart';

import '../../../core/theme/depth_tokens.dart';
import '../../../core/theme/liquid_glass/glass_style.dart';
import '../../../core/theme/palette.dart';
import '../glass_surface.dart';

/// An [AlertDialog] on Liquid Glass modal glass, and the plain
/// [AlertDialog] otherwise.
///
/// [AlertDialog] paints its own Material and cannot put a backdrop behind
/// it, so the glass path rebuilds its layout (icon, title, content,
/// end-aligned actions) inside [GlassSurface.modal], as `OsdDialog` does for
/// the OSD material. [backgroundColor] and [shape] only apply off Liquid Glass.
///
/// Either path gives the dialog a default focus target. A route opens with no
/// focused descendant, so on a remote the first D-pad press lands nowhere.
/// After the first frame, if nothing inside the route has taken focus (a PIN
/// pad or text field that autofocuses keeps it), focus goes to the last action
/// (the primary one), or the first when [destructive] so a stray Select does
/// not confirm a delete. The actions sit under their own container node so the
/// target is found by traversal order without keys on each caller's buttons;
/// that holds on the [AlertDialog] path too, where the container wraps a single
/// [OverflowBar] handed to [AlertDialog.actions]. The container is a plain
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

  @override
  void initState() {
    super.initState();
    // A content autofocus is only applied after the first frame's callbacks,
    // so the microtask hop lets it win before the fallback looks.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => Future<void>.microtask(_focusDefaultAction),
    );
  }

  @override
  void dispose() {
    _actionsNode.dispose();
    super.dispose();
  }

  void _focusDefaultAction() {
    if (!mounted) return;
    // The nearest scope above this state is the route's.
    final routeScope = FocusScope.of(context);
    if (routeScope.focusedChild != null) return;
    final targets = _actionsNode.traversalDescendants
        .where((node) => node.canRequestFocus && !node.skipTraversal)
        .toList();
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
    if (!GlassStyle.of(context)) {
      final actions = widget.actions;
      return AlertDialog(
        icon: widget.icon,
        title: widget.title,
        content: widget.content,
        actions: actions == null || actions.isEmpty
            ? actions
            : [_actionBar(actions)],
        backgroundColor: widget.backgroundColor,
        shape: widget.shape,
      );
    }
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
        borderRadius: BorderRadius.circular(DepthTokens.liquidDialogRadius),
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
                          24, icon == null ? 24 : 16, 24, 16),
                      child: DefaultTextStyle.merge(
                        style: (textTheme.headlineSmall ?? const TextStyle())
                            .copyWith(color: palette.textPrimary),
                        textAlign:
                            icon == null ? TextAlign.start : TextAlign.center,
                        child: title,
                      ),
                    ),
                  if (content != null)
                    Flexible(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                            24, title == null ? 24 : 0, 24, 24),
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
}
