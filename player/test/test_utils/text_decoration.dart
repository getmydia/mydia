import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fails if any rendered text carries a [TextDecoration].
///
/// Flutter's fallback text style, the one a [Text] inherits when no [Material]
/// or [DefaultTextStyle] ancestor supplies one, is red with a yellow double
/// underline. A [Text] with an explicit style *merges* over that default rather
/// than replacing it, so colour, size and weight look correct while
/// `decoration` survives untouched.
///
/// This asserts on [RichText] rather than [Text] deliberately: [RichText] is
/// what [Text] builds into once the styles are merged, so it holds the
/// effective style rather than the declared one.
///
/// The whole [InlineSpan] tree is walked, not just the root span. A plain
/// [Text] puts its merged style on the root, but a `Text.rich` can carry a
/// decoration on a descendant span, and a root-only check would wave it
/// through.
void expectNoDebugTextDecorations(WidgetTester tester) {
  final offenders = <String>[];

  void inspect(InlineSpan span) {
    final decoration = span.style?.decoration;
    if (decoration != null && decoration != TextDecoration.none) {
      offenders.add('"${span.toPlainText()}" has $decoration');
    }
  }

  // Hand-rolled rather than InlineSpan.visitChildren: that skips a TextSpan
  // whose own `text` is null, which is exactly the shape a styled wrapper span
  // around children takes.
  void walk(InlineSpan span) {
    inspect(span);
    if (span is TextSpan) {
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  for (final richText in tester.widgetList<RichText>(find.byType(RichText))) {
    walk(richText.text);
  }

  expect(
    offenders,
    isEmpty,
    reason: 'Text rendered with a decoration. This usually means the subtree '
        'has no Material ancestor and is inheriting Flutter\'s fallback debug '
        'style:\n${offenders.join('\n')}',
  );
}
