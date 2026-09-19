import 'package:flutter/widgets.dart';

import 'toast_controller.dart';
import 'toast_models.dart';

export 'toast_models.dart' show ToastAction, ToastKind;

/// Shows toasts in the nearest `ToastLayer`.
///
/// Resolve it before an `await` when the calling widget may be gone by the
/// time there is something to say:
///
/// ```dart
/// final toaster = Toaster.of(context);
/// await remove();
/// toaster.show('Removed', kind: ToastKind.success);
/// ```
class Toaster {
  const Toaster._(this._controller);

  final ToastController _controller;

  static Toaster of(BuildContext context) {
    final controller = maybeControllerOf(context);
    if (controller == null) {
      throw FlutterError.fromParts([
        ErrorSummary('No ToastLayer found in context.'),
        ErrorDescription(
          'Toaster.of() needs a ToastLayer above the calling widget. '
          "app.dart mounts one in MaterialApp.router's builder.",
        ),
        ErrorHint(
          'In a widget test, pass `builder: toastLayerBuilder` '
          '(test/test_utils/toast_harness.dart) to the MaterialApp.',
        ),
      ]);
    }
    return Toaster._(controller);
  }

  /// The layer's controller, or null outside one. For widgets that must keep
  /// working in isolated tests without a layer, such as `ToastObstruction`.
  ///
  /// Registers no dependency: a layer's controller never changes.
  static ToastController? maybeControllerOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ToasterScope>()?.controller;

  ToastHandle show(
    String message, {
    ToastKind kind = ToastKind.info,
    IconData? icon,
    ToastAction? action,
    Duration? duration,
  }) {
    final entry = _controller.show(
      message,
      kind: kind,
      icon: icon,
      action: action,
      duration: duration,
    );
    return ToastHandle._(_controller, entry.id);
  }
}

/// Closes the one toast it was issued for, and nothing else.
class ToastHandle {
  const ToastHandle._(this._controller, this._id);

  final ToastController _controller;
  final int _id;

  /// A no-op if the toast was already replaced, timed out or dismissed.
  void close() => _controller.close(_id);
}

/// Shorthand for `Toaster.of(context).show(...)`.
ToastHandle showToast(
  BuildContext context,
  String message, {
  ToastKind kind = ToastKind.info,
  IconData? icon,
  ToastAction? action,
  Duration? duration,
}) =>
    Toaster.of(context).show(
      message,
      kind: kind,
      icon: icon,
      action: action,
      duration: duration,
    );

/// Publishes a `ToastLayer`'s controller to its subtree.
class ToasterScope extends InheritedWidget {
  const ToasterScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final ToastController controller;

  @override
  bool updateShouldNotify(ToasterScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}
