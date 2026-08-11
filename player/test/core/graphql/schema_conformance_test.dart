import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// `gql` is a transitive dependency reached through graphql_flutter (via
// graphql -> gql_exec/gql_link). It is not exported by graphql_flutter, so the
// AST types and parser need direct imports; the same pattern is already used
// throughout core/graphql/*.dart and the controller tests.
// ignore: depend_on_referenced_packages
import 'package:gql/ast.dart';
// ignore: depend_on_referenced_packages
import 'package:gql/language.dart' show parseString;

/// Every GraphQL operation the player ships must name a root field the server
/// actually exposes.
///
/// This guards the failure that left favoriting dead in the player for the
/// entire life of the Flutter client. `toggleShowFavorite(showId:)` and
/// `toggleMovieFavorite(movieId:)` were written as inline Dart strings and
/// shipped against a schema whose only favorite mutation has always been
/// `toggleFavorite(mediaItemId:)`. Both calls failed validation on every tap,
/// the optimistic heart reverted, and nothing reported it.
///
/// Documents under `lib/graphql/**/*.graphql` are checked by graphql_codegen
/// against this same schema at build time, so they cannot drift. Operations
/// written inline as Dart string literals are invisible to codegen. This test
/// covers both, so a new inline operation is held to the same standard.
///
/// Deliberately shallow: root fields only. Codegen already does full
/// validation for the `.graphql` files, and full checking of inline documents
/// would mean reimplementing a validator here.
void main() {
  group('player GraphQL documents conform to the server schema', () {
    late Map<OperationType, Set<String>> rootFields;

    setUpAll(() {
      rootFields = _rootFieldsByOperation(
        parseString(File('lib/graphql/schema.graphql').readAsStringSync()),
      );
    });

    test('schema exposes the root types the player relies on', () {
      // A parse or lookup regression here would make every case below vacuous.
      expect(rootFields[OperationType.query], isNotEmpty);
      expect(rootFields[OperationType.mutation], isNotEmpty);
      expect(rootFields[OperationType.subscription], isNotEmpty);
      expect(rootFields[OperationType.mutation], contains('toggleFavorite'));
    });

    test('every operation names a root field the schema defines', () {
      final documents = _collectDocuments();

      // Guards against the collector silently matching nothing (a bad glob, a
      // moved directory) and reporting green over an empty set.
      expect(
        documents.length,
        greaterThan(20),
        reason: 'expected to find the player\'s GraphQL documents; '
            'found ${documents.length}',
      );

      final violations = <String>[];

      for (final doc in documents) {
        for (final definition in doc.ast.definitions) {
          if (definition is! OperationDefinitionNode) continue;
          final allowed = rootFields[definition.type] ?? const <String>{};

          for (final selection in definition.selectionSet.selections) {
            if (selection is! FieldNode) continue;
            final field = selection.name.value;
            if (field == '__typename' || allowed.contains(field)) continue;

            violations.add(
              '${doc.source}: ${definition.type.name} "$field" '
              'is not a field of the schema root',
            );
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason: 'GraphQL operations reference root fields the server does not '
            'expose:\n  ${violations.join('\n  ')}',
      );
    });

    test('the inline scanner sees both of Dart\'s triple-quote forms', () {
      // The scanner originally matched only `'''`, so an inline operation
      // written with `"""` would have slipped past the case above without
      // anything reporting it.
      final source = [
        "const a = r'''\nquery A { movie(id: \"1\") { id } }\n''';",
        'const b = r"""\nquery B { movie(id: "1") { id } }\n""";',
        'const c = """\nquery C { movie(id: "1") { id } }\n""";',
        "final d = gql(r'''\nquery D { movie(id: \"1\") { id } }\n''');",
      ].join('\n');

      final bodies =
          _tripleQuoted.allMatches(source).map((m) => m.group(3)!.trim());

      expect(bodies, hasLength(4));
      expect(bodies.every((body) => body.startsWith('query ')), isTrue);
    });

    test('a triple quote inside a comment does not desync the scan', () {
      // The failure this closes: an unanchored pattern treats the `"""` in the
      // comment as an opening delimiter, pairs it with the real one on the line
      // below, and every document after it in the file goes unscanned.
      final source = [
        '// Some note mentioning """ and \'\'\' in passing.',
        'const a = r"""',
        'query A { movie(id: "1") { id } }',
        '""";',
      ].join('\n');

      final bodies =
          _tripleQuoted.allMatches(source).map((m) => m.group(3)!.trim());

      expect(bodies, hasLength(1));
      expect(bodies.single, startsWith('query A'));
    });
  });
}

/// Maps each operation type to the field names of its root object, honouring
/// the schema's own `schema { query: ... }` block rather than assuming the
/// conventional `Query`/`Mutation` names. Mydia's roots are `RootQueryType`,
/// `RootMutationType`, and `RootSubscriptionType`.
Map<OperationType, Set<String>> _rootFieldsByOperation(DocumentNode schema) {
  final rootTypeNames = <OperationType, String>{};
  final objectFields = <String, Set<String>>{};

  for (final definition in schema.definitions) {
    if (definition is SchemaDefinitionNode) {
      for (final operation in definition.operationTypes) {
        rootTypeNames[operation.operation] = operation.type.name.value;
      }
    } else if (definition is ObjectTypeDefinitionNode) {
      objectFields[definition.name.value] =
          definition.fields.map((f) => f.name.value).toSet();
    }
  }

  return {
    for (final entry in rootTypeNames.entries)
      entry.key: objectFields[entry.value] ?? const <String>{},
  };
}

class _Document {
  const _Document(this.source, this.ast);
  final String source;
  final DocumentNode ast;
}

/// Collects `.graphql` files plus GraphQL operations written inline as
/// triple-quoted Dart strings.
List<_Document> _collectDocuments() {
  final documents = <_Document>[];

  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File) continue;
    final path = entity.path;

    if (path.endsWith('.graphql')) {
      documents.add(_Document(path, parseString(entity.readAsStringSync())));
      continue;
    }

    if (!path.endsWith('.dart')) continue;
    if (path.endsWith('.g.dart') ||
        path.endsWith('.graphql.dart') ||
        path.endsWith('.freezed.dart')) {
      continue;
    }

    for (final match in _tripleQuoted.allMatches(entity.readAsStringSync())) {
      final isRaw = match.group(1) == 'r';
      var body = match.group(3)!;
      // Non-raw literals escape interpolation, so `\$id` in the source is `$id`
      // in the document the server receives.
      if (!isRaw) body = body.replaceAll(r'\$', r'$');

      // Only triple-quoted blocks that open with a GraphQL keyword are
      // candidates. Anything else is ordinary prose or code. A block that does
      // look like GraphQL and still fails to parse throws here rather than
      // being skipped, which is the point.
      if (!_graphqlOpener.hasMatch(body)) continue;
      documents.add(_Document(path, parseString(body)));
    }
  }

  return documents;
}

/// Matches both of Dart's triple-quote forms, raw or not: group 1 is the `r`
/// prefix, group 2 the opening delimiter, group 3 the body. The backreference
/// on group 2 keeps a `'''` block from being closed by a `"""`.
///
/// Matching only `'''` would leave a hole wide enough to defeat this file: an
/// inline operation written with `"""` would never be scanned.
///
/// The leading `[=(]` anchor matters more than it looks. Without it, a triple
/// quote appearing anywhere else — most often inside a comment describing one —
/// is read as an opening delimiter, pairs with the *real* opening delimiter
/// below it, and shifts every subsequent pairing in that file. Coverage then
/// drops silently for the rest of the file rather than failing. Every inline
/// document in this codebase is either assigned (`= r'''`) or passed straight
/// to `gql(` , so anchoring costs nothing and removes the failure mode.
final RegExp _tripleQuoted = RegExp(
  '[=(]\\s*(r?)(\'\'\'|""")(.*?)\\2',
  dotAll: true,
);
final RegExp _graphqlOpener =
    RegExp(r'^\s*(query|mutation|subscription|fragment)\s', multiLine: false);
