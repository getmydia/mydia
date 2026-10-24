import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

/// Named arguments whose string value is shown to the viewer.
const _uiArguments = {
  'label',
  'labelText',
  'hintText',
  'helperText',
  'errorText',
  'title',
  'subtitle',
  'tooltip',
  'message',
  'semanticLabel',
  'semanticsLabel',
  'text',
};

class UntranslatedLiteral {
  const UntranslatedLiteral(this.path, this.line, this.text);
  final String path;
  final int line;
  final String text;
  @override
  String toString() => '$path:$line  $text';
}

/// Literal English handed straight to a widget in [source]. Unresolved AST,
/// so `Text('x')` without `const` parses as a method call: both are checked.
List<UntranslatedLiteral> findUntranslated(
  String source, {
  required String path,
}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final visitor = _Visitor(path, source, unit.lineInfo);
  unit.accept(visitor);
  return visitor.found;
}

class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this.path, this.source, this.lineInfo);
  final String path;
  final String source;
  final LineInfo lineInfo;
  final found = <UntranslatedLiteral>[];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (node.constructorName.type.name.lexeme == 'Text') {
      _checkFirstPositional(node.argumentList);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.target == null && node.methodName.name == 'Text') {
      _checkFirstPositional(node.argumentList);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    if (_uiArguments.contains(node.name.label.name)) _check(node.expression);
    super.visitNamedExpression(node);
  }

  void _checkFirstPositional(ArgumentList args) {
    final first = args.arguments.firstOrNull;
    if (first != null && first is! NamedExpression) _check(first);
  }

  void _check(Expression e) {
    final words = switch (e) {
      SimpleStringLiteral(:final value) => value,
      AdjacentStrings() => _literalText(e),
      StringInterpolation() => _literalText(e),
      _ => null,
    };
    if (words == null || !RegExp(r'[A-Za-z]').hasMatch(words)) return;
    final line = lineInfo.getLocation(e.offset).lineNumber;
    if (source.split('\n')[line - 1].contains('// l10n-ignore')) return;
    final raw = e is SimpleStringLiteral
        ? e.value
        : source.substring(e.offset + 1, e.end - 1);
    found.add(UntranslatedLiteral(path, line, raw));
  }

  /// The literal parts of a string, without interpolated expressions.
  String _literalText(StringLiteral s) => switch (s) {
        SimpleStringLiteral(:final value) => value,
        StringInterpolation(:final elements) =>
          elements.whereType<InterpolationString>().map((p) => p.value).join(),
        AdjacentStrings(:final strings) => strings.map(_literalText).join(),
      };
}
