# GraphQL Client Setup

This directory contains the GraphQL schema, query documents, and generated code for the Mydia player client.

## Directory Structure

```
lib/graphql/
├── schema.graphql -> ../../../../priv/graphql/schema.graphql  # Symlink to server schema
├── fragments/              # Reusable GraphQL fragments
├── queries/               # GraphQL queries
├── mutations/             # GraphQL mutations
└── *.graphql.dart         # Auto-generated Dart code (do not edit manually)
```

**Note:** The schema is a symlink to the server's exported schema in `priv/graphql/`. This ensures both client and server always use the same schema definition.

The Mydia browse documents (`home_rows`, `continue_watching_full`,
`recently_added_full`, `library_filtered`, `listings`, `calendar`,
`collections`) are checked `.graphql` files, so codegen and the schema guard
validate them. `queries/mydia_queries.dart` re-exports the generated document
nodes that `MydiaSource` sends, and the `...Legacy` operations beside some of
them are fallbacks for servers older than the field they drop. Each Mydia
instance sends them through its own `MydiaClient`; see
`lib/core/sources/README.md`.

## Setup

### 1. Dependencies

The required dependencies are already configured in `pubspec.yaml`:

- `graphql_flutter: ^5.1.0` - GraphQL client
- `graphql_codegen: ^0.14.0` - Code generation (dev dependency)
- `flutter_secure_storage: ^9.0.0` - Secure storage for auth tokens
- `hive_flutter: ^1.1.0` - Local caching for GraphQL

### 2. Initialization

Initialize Hive for GraphQL caching in your app's main function:

```dart
import 'package:graphql_flutter/graphql_flutter.dart';

import 'core/storage/app_hive.dart';

void main() async {
  await initAppHive();
  await HiveStore.open();
  runApp(MyApp());
}
```

`initAppHive` rather than graphql_flutter's `initHiveForFlutter`: the latter
hard-wires its base path to `getApplicationDocumentsDirectory()`, which is the
user's own Documents folder on desktop. See `core/storage/app_hive.dart`.

### 3. Code Generation

To generate typed Dart classes from GraphQL documents:

```bash
flutter pub run build_runner build
# or for continuous generation during development:
flutter pub run build_runner watch
```

**Note:** Flutter SDK is required for code generation. The GraphQL documents and configuration are ready, but generation should be run when Flutter is available.

## Usage

### Using the GraphQL Client

The GraphQL client is provided via Riverpod and automatically includes authentication headers.

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/graphql_provider.dart';

class MyWidget extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(graphqlClientProvider);

    if (client == null) {
      return Text('Not connected to server');
    }

    return GraphQLProvider(
      client: ValueNotifier(client),
      child: Query(
        options: QueryOptions(
          document: gql(homeScreenQuery),
          variables: {
            'continueWatchingLimit': 10,
            'recentlyAddedLimit': 20,
          },
        ),
        builder: (result, {refetch, fetchMore}) {
          if (result.isLoading) {
            return CircularProgressIndicator();
          }

          if (result.hasException) {
            return Text('Error: ${result.exception}');
          }

          final data = result.data!;
          // Use the data...
        },
      ),
    );
  }
}
```

### Authentication

There is no global auth state. The client talks to the bound Mydia instance
(`boundMydiaClientProvider`), which owns its token and refresh. Add or remove
the server through the sources screens (`removeMydiaInstance` signs out).

## Available Queries

### Discovery Queries (Home Screen)

- `HomeScreen` - Get continue watching, recently added, and up next items
- `Search` - Search across movies and TV shows

### Browse Queries

- `MoviesList` - List movies with pagination
- `TvShowsList` - List TV shows with pagination
- `MovieDetail` - Get detailed movie information
- `TvShowDetail` - Get detailed TV show information
- `SeasonEpisodes` - Get episodes for a specific season

## Available Mutations

### Progress Tracking

- `UpdateMovieProgress` - Update playback position for a movie
- `UpdateEpisodeProgress` - Update playback position for an episode

### Watched Status

- `MarkMovieWatched` / `MarkMovieUnwatched` - Mark movie as watched/unwatched
- `MarkEpisodeWatched` / `MarkEpisodeUnwatched` - Mark episode as watched/unwatched
- `MarkSeasonWatched` - Mark all episodes in a season as watched

### Favorites

- `ToggleFavorite` - Toggle favorite status for a media item

## Schema Updates

When the backend GraphQL schema changes:

1. Export the updated schema from the backend:
   ```bash
   ./dev mix mydia.graphql export
   ```

2. Regenerate the Dart code:
   ```bash
   ./dev flutter pub run build_runner build
   ```

The Flutter client uses a symlink to the server schema, so no copying is needed.

## Validating Operations

To validate that all client GraphQL operations match the server schema:

```bash
./dev mix mydia.graphql validate
```

This will:
1. Export the current server schema
2. Validate all `.graphql` files against it using graphql-inspector
3. Report any mismatches or errors

Run this before committing changes to catch schema/operation mismatches early.

## Best Practices

1. **Use fragments** for repeated field selections to keep queries DRY
2. **Limit query depth** to avoid over-fetching data
3. **Use pagination** for lists to improve performance
4. **Handle errors gracefully** with proper error UI
5. **Cache appropriately** using the built-in GraphQL cache
6. **Invalidate cache** after mutations to keep data fresh
