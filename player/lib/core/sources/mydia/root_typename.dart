/// The root `__typename` the generated parsers require.
///
/// A transport returns a response's bare `data` map, and no generated document
/// selects the root's `__typename`, so `Query$X.fromJson` would fail its cast.
library;

Map<String, dynamic> rootQuery(Map<String, dynamic> data) =>
    {'__typename': 'RootQueryType', ...data};

Map<String, dynamic> rootMutation(Map<String, dynamic> data) =>
    {'__typename': 'RootMutationType', ...data};
