import 'package:flutter/widgets.dart';

/// The router's root navigator.
///
/// Lives here rather than in `app_router.dart` so widgets that need to reach
/// the app's navigation stack do not have to import the whole route table.
///
/// The one caller outside the router is the cast bar: `app.dart` mounts it
/// above the router so it floats over every route, which also puts it outside
/// this navigator, and a dialog it opens has to land here.
final rootNavigatorKey = GlobalKey<NavigatorState>();
