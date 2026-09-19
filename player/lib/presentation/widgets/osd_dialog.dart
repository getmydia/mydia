import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';
import '../../core/theme/depth_tokens.dart';
import 'glass_surface.dart';

/// An [AlertDialog]-shaped dialog on the OSD material.
///
/// [AlertDialog] paints its own Material and has no way to put a backdrop
/// blur behind it, so this rebuilds its layout (title, scrollable content,
/// end-aligned actions) inside [GlassSurface.osd]. The [IntrinsicWidth] is
/// kept from [AlertDialog], so content that already worked there, including
/// a `SizedBox(width: double.maxFinite)` list, sizes the same way here.
class OsdDialog extends StatelessWidget {
  const OsdDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const <Widget>[],
    this.contentPadding = const EdgeInsets.fromLTRB(24, 0, 24, 24),
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      child: GlassSurface.osd(
        borderRadius: const BorderRadius.all(
          Radius.circular(DepthTokens.radiusOsdSheet),
        ),
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                child: IconTheme.merge(
                  data: const IconThemeData(color: AppColors.textPrimary),
                  child: DefaultTextStyle.merge(
                    style: (textTheme.headlineSmall ?? const TextStyle())
                        .copyWith(color: AppColors.textPrimary),
                    child: title,
                  ),
                ),
              ),
              Flexible(
                child: Padding(
                  padding: contentPadding,
                  child: DefaultTextStyle.merge(
                    style: (textTheme.bodyMedium ?? const TextStyle())
                        .copyWith(color: AppColors.textSecondary),
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
    );
  }
}
