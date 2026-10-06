/// What a remote `LoadContent` or a pull back to this device needs to know
/// about the item it names, read from the instance the command came through.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/remote/load_content_navigation.dart';
import '../../../domain/sources/item.dart';
import '../sources/source_browse_providers.dart';

Future<ItemDetail> fetchLoadContentItem(WidgetRef ref, ItemRef itemRef) {
  final provider = sourceItemProvider(itemRef);
  return readDetailKeepingAlive(ref,
      provider: provider, future: provider.future);
}
