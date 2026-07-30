/// Merges a paginated connection response into the accumulated one.
///
/// Written for `FetchMoreOptions.updateQuery`. The library writes the result
/// back under the *original* request key and rebroadcasts it, so page
/// accumulation becomes a cache concern rather than controller-local mutable
/// state.
Map<String, dynamic>? mergeConnection(
  String field,
  Map<String, dynamic>? previous,
  Map<String, dynamic>? fetched,
) {
  if (fetched == null) return previous;
  if (previous == null) return fetched;

  final previousConnection = previous[field] as Map<String, dynamic>?;
  final fetchedConnection = fetched[field] as Map<String, dynamic>?;
  if (previousConnection == null || fetchedConnection == null) return fetched;

  return {
    ...fetched,
    field: {
      ...fetchedConnection,
      'edges': [
        ...(previousConnection['edges'] as List<dynamic>? ?? const []),
        ...(fetchedConnection['edges'] as List<dynamic>? ?? const []),
      ],
      // The newer page's pageInfo is the one that says whether more remains.
      'pageInfo': fetchedConnection['pageInfo'],
      'totalCount':
          fetchedConnection['totalCount'] ?? previousConnection['totalCount'],
    },
  };
}
