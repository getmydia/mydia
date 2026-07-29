import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../domain/models/search_result.dart';

part 'search_controller.g.dart';

/// Shown instead of the raw GraphQL error when a response looks like a
/// client/server schema mismatch rather than an ordinary failure.
///
/// The web player ships inside the server image and always matches it, but
/// the same Flutter codebase also ships as an Android APK and an iOS
/// TestFlight build on an independent release cadence, and nothing
/// negotiates the GraphQL schema version between them. An older app talking
/// to an upgraded server — e.g. one still requesting the retired
/// `SearchResults.results` field — gets a validation error here instead of
/// data.
const String _schemaMismatchErrorMessage =
    "This app version doesn't match your Mydia server. Update the app to "
    'search your library.';

/// Absinthe's GraphQL validation phase uses these phrasings for a query
/// asking about a field, argument, or type the server's schema no longer
/// has — the shape a stale client produces against an upgraded server,
/// distinct from a network failure or an ordinary server-side error.
bool _looksLikeSchemaMismatch(OperationException exception) {
  return exception.graphqlErrors.any((error) {
    final message = error.message.toLowerCase();
    return message.contains('cannot query field') ||
        message.contains('unknown argument') ||
        message.contains('unknown type') ||
        message.contains('unknown field');
  });
}

/// Renders a GraphQL failure for display, substituting a legible message for
/// the raw exception when it looks like a schema mismatch.
String describeSearchError(Object? exception) {
  if (exception is OperationException && _looksLikeSchemaMismatch(exception)) {
    return _schemaMismatchErrorMessage;
  }
  return exception.toString();
}

const String searchQuery = r'''
query Search($query: String!, $types: [SearchResultType], $first: Int) {
  search(query: $query, types: $types, first: $first) {
    totalCount
    sections {
      type
      totalCount
      results {
        id
        type
        title
        year
        subtitle
        seasonNumber
        episodeNumber
        parentId
        score
        artwork {
          posterUrl
          backdropUrl
          thumbnailUrl
        }
      }
    }
  }
}
''';

/// State for the search screen
class SearchState {
  final String query;
  final Set<SearchResultType> selectedTypes;
  final SearchResults? results;
  final bool isLoading;
  final String? error;

  const SearchState({
    this.query = '',
    this.selectedTypes = const {},
    this.results,
    this.isLoading = false,
    this.error,
  });

  SearchState copyWith({
    String? query,
    Set<SearchResultType>? selectedTypes,
    SearchResults? results,
    bool? isLoading,
    String? error,
    bool clearResults = false,
    bool clearError = false,
  }) {
    return SearchState(
      query: query ?? this.query,
      selectedTypes: selectedTypes ?? this.selectedTypes,
      results: clearResults ? null : (results ?? this.results),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  bool get hasResults => results != null && results!.sections.isNotEmpty;

  bool get isEmpty =>
      query.isNotEmpty && !isLoading && results != null && results!.isEmpty;
}

@riverpod
class SearchController extends _$SearchController {
  /// Id of the most recently started request.
  ///
  /// The 400ms debounce narrows overlap but does not remove it: a request for
  /// "al" issued before the user finished typing "alien" can still be in
  /// flight when the "alien" request completes, and on a slow connection it
  /// lands last. Without this guard its stale results replace the newer ones
  /// and the screen shows matches for a query the search box no longer holds.
  /// Anything that supersedes a search — a newer search, [clear], or emptying
  /// the query — bumps the id, and a response carrying a stale id is dropped.
  int _requestId = 0;

  @override
  SearchState build() {
    return const SearchState();
  }

  void updateQuery(String query) {
    state = state.copyWith(query: query, clearError: true);
  }

  void toggleType(SearchResultType type) {
    final newTypes = Set<SearchResultType>.from(state.selectedTypes);
    if (newTypes.contains(type)) {
      newTypes.remove(type);
    } else {
      newTypes.add(type);
    }
    state = state.copyWith(selectedTypes: newTypes);
  }

  void clearFilters() {
    state = state.copyWith(selectedTypes: {});
  }

  /// Replaces the whole filter set. Used when a `type` query parameter seeds the
  /// screen and when a section's "Show all" narrows to that one section.
  void setTypes(Set<SearchResultType> types) {
    state = state.copyWith(selectedTypes: types);
  }

  Future<void> search() async {
    final query = state.query.trim();
    if (query.isEmpty) {
      _requestId++;
      state = state.copyWith(clearResults: true, clearError: true);
      return;
    }

    final requestId = ++_requestId;
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final client = await ref.read(asyncGraphqlClientProvider.future);

      final variables = <String, dynamic>{
        'query': query,
        'first': 50,
      };

      // Add type filter if any types are selected
      if (state.selectedTypes.isNotEmpty) {
        variables['types'] =
            state.selectedTypes.map((t) => t.apiValue).toList();
      }

      final result = await client.query(
        QueryOptions(
          document: gql(searchQuery),
          variables: variables,
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );

      // A newer search (or a clear) started while this one was in flight, so
      // this response is stale no matter how it turned out.
      if (requestId != _requestId) return;

      if (result.hasException) {
        state = state.copyWith(
          isLoading: false,
          error: describeSearchError(result.exception),
        );
        return;
      }

      if (result.data == null || result.data!['search'] == null) {
        state = state.copyWith(
          isLoading: false,
          results: SearchResults.empty,
        );
        return;
      }

      final searchResults = SearchResults.fromJson(
        result.data!['search'] as Map<String, dynamic>,
      );

      state = state.copyWith(
        isLoading: false,
        results: searchResults,
      );
    } catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        isLoading: false,
        error: describeSearchError(e),
      );
    }
  }

  void clear() {
    _requestId++;
    state = const SearchState();
  }
}
