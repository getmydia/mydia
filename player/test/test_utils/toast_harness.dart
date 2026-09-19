import 'package:flutter/widgets.dart';
import 'package:player/presentation/widgets/toast/toast_layer.dart';

/// A `MaterialApp.builder` that mounts a [ToastLayer] the way `app.dart`
/// does. Screen tests that trigger a toast need it: `Toaster.of` throws
/// without a layer above the caller.
///
/// ```dart
/// MaterialApp(builder: toastLayerBuilder, home: ...)
/// ```
Widget toastLayerBuilder(BuildContext context, Widget? child) =>
    ToastLayer(child: child ?? const SizedBox.shrink());
