import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../domain/models/search_result.dart';

part 'search_controller.g.dart';

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
      state = state.copyWith(clearResults: true, clearError: true);
      return;
    }

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

      if (result.hasException) {
        state = state.copyWith(
          isLoading: false,
          error: result.exception.toString(),
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
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  void clear() {
    state = const SearchState();
  }
}
