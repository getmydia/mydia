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
void expectNoDebugTextDecorations(WidgetTester tester) {
  final offenders = <String>[];

  for (final richText in tester.widgetList<RichText>(find.byType(RichText))) {
    final decoration = richText.text.style?.decoration;
    if (decoration != null && decoration != TextDecoration.none) {
      offenders.add('"${richText.text.toPlainText()}" has $decoration');
    }
  }

  expect(
    offenders,
    isEmpty,
    reason: 'Text rendered with a decoration. This usually means the subtree '
        'has no Material ancestor and is inheriting Flutter\'s fallback debug '
        'style:\n${offenders.join('\n')}',
  );
}
