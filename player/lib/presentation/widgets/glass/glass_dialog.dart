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
class GlassDialog extends StatelessWidget {
  const GlassDialog({
    super.key,
    this.icon,
    this.title,
    this.content,
    this.actions,
    this.backgroundColor,
    this.shape,
  });

  final Widget? icon;
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final Color? backgroundColor;
  final ShapeBorder? shape;

  @override
  Widget build(BuildContext context) {
    if (!GlassStyle.of(context)) {
      return AlertDialog(
        icon: this.icon,
        title: this.title,
        content: this.content,
        actions: this.actions,
        backgroundColor: backgroundColor,
        shape: shape,
      );
    }
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final icon = this.icon;
    final title = this.title;
    final content = this.content;
    final actions = this.actions ?? const <Widget>[];
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
                      child: OverflowBar(
                        alignment: MainAxisAlignment.end,
                        spacing: 8,
                        children: actions,
                      ),
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
