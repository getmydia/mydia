import 'query_key.dart';

/// Source keys are named `<sourceId>/<op>` (see `SourceKeys`); anything
/// else is a legacy key and shares the empty group.
String cacheGroupOf(QueryKey key) {
  final name = key.operationName;
  final slash = name.indexOf('/');
  return slash < 0 ? '' : name.substring(0, slash);
}
