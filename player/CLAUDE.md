# Flutter Player - Development Guidelines

This is the Flutter web client for Mydia, built for streaming media playback.

## Project Overview

- **Platform**: Flutter Web (served through Phoenix at `/player`)
- **State Management**: Riverpod with code generation
- **Routing**: go_router with hash-based URLs
- **Data Layer**: GraphQL via graphql_flutter with codegen
- **Storage**: flutter_secure_storage (credentials), Hive (cache)

## Development Commands

**Always use the `./dev` wrapper from the project root:**

```bash
./dev up -d               # Start everything (Phoenix + Flutter dev server)
./dev player logs         # Follow Flutter dev server logs (press R for hot restart)
./dev player restart      # Restart Flutter dev server
./dev player setup        # Install deps and run code generation
./dev player build        # Build AND deploy to Phoenix (for production)
./dev player icons        # Regenerate web icons from assets/*.svg (--check verifies)
./dev flutter pub get     # Install dependencies
./dev flutter analyze     # Run static analysis
./dev flutter test        # Run tests
```

### Development

Access the player at: **http://localhost:4000/player**

Phoenix reverse-proxies to the Flutter dev server, giving you:
- Hot restart support (press `R` in `./dev player logs`)
- Proper auth injection (your session token is automatically passed to Flutter)
- Single URL (no need to remember different ports)

### Production Builds

**Use `./dev player build`** for production builds. This command:
1. Runs `flutter build web --base-href /player/`
2. Copies output to `priv/static/player/` (served directly by Phoenix)

In production, Phoenix serves the static files without the dev server proxy.

## Architecture

This project follows Clean Architecture with three layers:

```
lib/
├── core/           # Infrastructure (theme, routing, auth, GraphQL)
├── domain/         # Business models (pure Dart, no Flutter)
└── presentation/   # UI (screens, widgets, controllers)
```

### Layer Responsibilities

- **core/**: App configuration, routing, theme, GraphQL client, auth service
- **domain/models/**: Plain Dart classes representing business entities
- **presentation/screens/**: Full-page widgets with their controllers
- **presentation/widgets/**: Reusable UI components

## Dart & Flutter Guidelines

### Immutability & Const

**Always** use `const` constructors where possible:

```dart
// GOOD
const EdgeInsets.all(16)
const Text('Hello')
const SizedBox(height: 8)

// BAD - will trigger linter warning
EdgeInsets.all(16)
Text('Hello')
SizedBox(height: 8)
```

### Widget Keys

**Always** provide keys for widgets in lists:

```dart
// GOOD
ListView.builder(
  itemBuilder: (context, index) {
    final item = items[index];
    return MediaCard(key: ValueKey(item.id), item: item);
  },
)

// BAD
ListView.builder(
  itemBuilder: (context, index) => MediaCard(item: items[index]),
)
```

### Null Safety

**Never** use the bang operator (`!`) without good reason:

```dart
// GOOD - handle null explicitly
final title = movie.title ?? 'Untitled';

// GOOD - early return
if (movie == null) return const SizedBox.shrink();

// BAD - crashes if null
final title = movie!.title;
```

### Avoid Print Statements

The linter forbids `print()`. Use proper logging or debugPrint:

```dart
// GOOD
debugPrint('Loading movie: ${movie.id}');

// BAD - linter error
print('Loading movie');
```

## Riverpod Guidelines

### Provider Naming

Providers should be named descriptively with the `Provider` suffix:

```dart
// Generated providers (from riverpod_generator)
@riverpod
Future<List<Movie>> movies(MoviesRef ref) async { ... }
// Usage: ref.watch(moviesProvider)

// Manual providers
final authStateProvider = StateNotifierProvider<AuthNotifier, AuthState>(...);
```

### Watching vs Reading

```dart
// GOOD - watch for reactive updates in build methods
@override
Widget build(BuildContext context, WidgetRef ref) {
  final movies = ref.watch(moviesProvider);
  return MovieList(movies: movies);
}

// GOOD - read for one-time access in callbacks
onPressed: () {
  ref.read(authProvider.notifier).logout();
}

// BAD - watching in callbacks causes unnecessary rebuilds
onPressed: () {
  ref.watch(authProvider.notifier).logout(); // Don't do this
}
```

### Async Providers

Handle loading and error states properly:

```dart
@override
Widget build(BuildContext context, WidgetRef ref) {
  final asyncMovies = ref.watch(moviesProvider);

  return asyncMovies.when(
    data: (movies) => MovieGrid(movies: movies),
    loading: () => const ShimmerGrid(),
    error: (error, stack) => ErrorWidget(message: error.toString()),
  );
}
```

## GraphQL Guidelines

### Query Organization

Store queries in `priv/graphql/` and use codegen:

```bash
./dev flutter pub run build_runner build
```

### Error Handling

**Always** handle GraphQL errors gracefully:

```dart
// GOOD
final result = await client.query(options);
if (result.hasException) {
  return Result.error(result.exception.toString());
}
return Result.success(result.data);

// BAD - crashes on error
final data = result.data!['movies'];
```

## Widget Guidelines

### Prefer Composition Over Inheritance

```dart
// GOOD - composition
class MediaCard extends StatelessWidget {
  final Widget? overlay;
  final VoidCallback? onTap;
  // ...
}

// BAD - inheritance for customization
class SpecialMediaCard extends MediaCard { ... }
```

### Extract Reusable Widgets

If a widget pattern appears 3+ times, extract it:

```dart
// presentation/widgets/shimmer_card.dart
class ShimmerCard extends StatelessWidget {
  final double width;
  final double height;

  const ShimmerCard({
    super.key,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) { ... }
}
```

### Use Named Parameters

For widgets with more than 2 parameters:

```dart
// GOOD
MediaCard(
  title: movie.title,
  imageUrl: movie.posterUrl,
  onTap: () => context.go('/movies/${movie.id}'),
)

// BAD - positional parameters are hard to read
MediaCard(movie.title, movie.posterUrl, () => context.go(...))
```

## Navigation (go_router)

### Route Paths

Define routes as constants:

```dart
// core/router/routes.dart
abstract class Routes {
  static const home = '/';
  static const movies = '/movies';
  static String movieDetail(String id) => '/movies/$id';
}
```

### Navigation Patterns

```dart
// Navigate to new screen
context.go(Routes.movieDetail(movie.id));

// Push onto stack (keeps back button)
context.push(Routes.movieDetail(movie.id));

// Replace current screen
context.replace(Routes.login);
```

## Testing Guidelines

### Widget Tests

```dart
testWidgets('MediaCard shows title', (tester) async {
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(
        home: MediaCard(title: 'Test Movie', imageUrl: ''),
      ),
    ),
  );

  expect(find.text('Test Movie'), findsOneWidget);
});
```

### Provider Tests

```dart
test('authProvider starts unauthenticated', () {
  final container = ProviderContainer();
  addTearDown(container.dispose);

  expect(
    container.read(authStateProvider),
    equals(const AuthState.unauthenticated()),
  );
});
```

## Common Patterns

### Loading States with Shimmer

Use the existing shimmer widgets for loading placeholders:

```dart
asyncValue.when(
  data: (items) => ContentRail(items: items),
  loading: () => const ShimmerRail(),
  error: (e, _) => Text('Error: $e'),
)
```

### Cached Images

**Always** use CachedNetworkImage for network images:

```dart
CachedNetworkImage(
  imageUrl: movie.posterUrl,
  placeholder: (_, __) => const ShimmerCard(),
  errorWidget: (_, __, ___) => const Icon(Icons.error),
)
```

## Code Generation

After modifying Riverpod providers or GraphQL queries, run:

```bash
./dev flutter pub run build_runner build
```

Generated files (`*.g.dart`) are excluded from analysis and should not be edited manually.

## Performance Tips

- Use `const` constructors to enable widget caching
- Prefer `ListView.builder` over `ListView` for long lists
- Use `AutoDispose` providers to free memory when not in use
- Avoid unnecessary `setState` calls - let Riverpod handle reactivity
- Use `RepaintBoundary` for complex widgets that repaint independently
