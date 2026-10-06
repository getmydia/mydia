# GraphQL documents

This directory holds the Mydia schema, the operation documents the player
sends, and the Dart generated from them. There is no client setup here: each
Mydia instance sends these documents through its own `MydiaClient` (see
`lib/core/sources/README.md`).

## Layout

```
lib/graphql/
├── schema.graphql -> ../../../priv/graphql/schema.graphql  # symlink to the server schema
├── fragments/   # reusable fragments
├── queries/     # queries (and the Mydia browse documents)
├── mutations/   # mutations
└── *.graphql.dart   # generated, never edited by hand
```

The schema is a symlink to the server's exported schema, so the client and the
server always read the same definition.

`queries/mydia_documents.graphql` holds the documents only the Mydia source
sends: the instance identity (`MydiaInstanceIdentity`) and continue watching
(`MydiaContinueWatching`). `queries/mydia_queries.dart` re-exports the
generated document nodes `MydiaSource` sends.

## Adding a document

1. Write the operation in a `.graphql` file under `queries/` or `mutations/`.
   Import shared fragments with `#import '../fragments/x.graphql'`.
2. Run codegen:

   ```bash
   ./dev flutter pub run build_runner build --delete-conflicting-outputs
   ```

3. Send it through the instance's client and parse the result:

   ```dart
   final data = await client.request(documentNodeQueryMovieDetail, {'id': id});
   final movie = Query$MovieDetail.fromJson(rootQuery(data));
   ```

   `MydiaClient.request` sends one document. `MydiaClient.query` adds a
   fallback (below). Mutations use `documentNodeMutation<Name>` and
   `Mutation$<Name>.fromJson(rootQuery(data))`.

Put operations in `.graphql` files, never in inline Dart strings: codegen
validates only the files, and an inline string gets no schema check.

## Fallbacks for older servers

When a field is newer than some servers the player still supports, keep the
old shape as a second operation named `<Op>Legacy` and put a comment above it
naming the server version that introduced the field. Send the pair with
`MydiaClient.query(document, fallback: legacyDocument)`: an unknown-field error
retries the fallback, and the client remembers the downgrade for that instance.
Pass `fallbackVariables` when the fallback takes different variables.

Delete the pair once `Compatibility.minServerVersion` reaches that version.
`compareCore` ignores prerelease suffixes, so the floor has to be the first core
version whose every build carries the field, not the release whose betas
introduced it. None are left at 0.15.0.

## Guards

- `test/graphql/schema_conformance_test.dart` parses every document the player
  ships and asserts each root field exists in the schema. It checks root
  fields only; codegen is the real validator.
- `test/graphql/no_orphan_documents_test.dart` fails when an operation in a
  `.graphql` file is never referenced as `documentNode<Query|Mutation><Name>`
  from non-generated code under `lib/`. Delete the document or use it.

## Updating the schema

When the backend schema changes:

```bash
./dev mix mydia.graphql export
./dev flutter pub run build_runner build --delete-conflicting-outputs
./dev mix mydia.graphql validate   # checks every .graphql file against it
```

No copying is needed, because the schema is a symlink.
