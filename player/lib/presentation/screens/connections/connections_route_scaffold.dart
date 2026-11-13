/// The frame of a full-window Servers & devices route: the window title row
/// with a back button over the page's body.
library;

import 'package:flutter/material.dart';

import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/theme/palette.dart';
import '../../widgets/window_chrome/window_title_row.dart';

/// Follows `DiagnosticsScreen`: these routes are pushed outside the shell, so
/// they own the title-bar band. The body sits under `removeBand`, or the
/// ambient `MediaQuery.padding.top` would add the band again under the bar.
class ConnectionsRouteScaffold extends StatelessWidget {
  const ConnectionsRouteScaffold({
    super.key,
    required this.title,
    required this.body,
  });

  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) => WindowChromeInsets.removeBand(
        child: Builder(
          builder: (context) => Scaffold(
            appBar: WindowTitleBar(
              height: WindowTitleRow.heightOf(context),
              leading: const BackButton(),
              title: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              showCast: false,
              // A flat fill in the app-bar colour, as the plain AppBar had.
              decorate: (row) => ColoredBox(
                color: Theme.of(context).appBarTheme.backgroundColor ??
                    context.palette.background,
                child: row,
              ),
            ),
            body: body,
          ),
        ),
      );
}
