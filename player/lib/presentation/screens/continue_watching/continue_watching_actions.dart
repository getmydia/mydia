import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../../../core/graphql/graphql_provider.dart';
import '../../../core/graphql/watch/invalidation_rules.dart';
import '../../../core/graphql/watch/watcher_registry.dart';
import '../../../graphql/mutations/remove_from_continue_watching.graphql.dart';

/// Hides a movie or show from Continue Watching, server-side.
///
/// Shared by the home rail and the `/continue-watching` grid, which both offer
/// the action and would otherwise each carry their own copy of the mutation,
/// the invalidation and the ordering rule below.
///
/// Deliberately does not touch controller state. Each caller owns its own
/// optimistic splice and its own revert, because the two hold different shapes
/// and only the caller knows what to put back on failure.
///
/// [mediaItemId] is `ContinueWatchingItem.continueWatchingKey`: the movie, or
/// for an episode card its *show*. The server refuses an episode id.
///
/// Throws whatever the mutation failed with, so the caller reverts and reports.
Future<void> removeFromContinueWatching(Ref ref, String mediaItemId) async {
  // Read before the first await, not after. These controllers are auto-dispose,
  // so a viewer who navigates away while the mutation is in flight tears `ref`
  // down, and a later read would throw `UnmountedRefException` — swallowing
  // the invalidation into the caller's revert-on-error path and leaving every
  // other surface showing a card the server has already hidden.
  final invalidator = ref.read(invalidatorProvider);

  final client = await ref.read(asyncGraphqlClientProvider.future);
  final result = await client.mutate(
    MutationOptions(
      document: documentNodeMutationRemoveFromContinueWatching,
      variables: Variables$Mutation$RemoveFromContinueWatching(
        mediaItemId: mediaItemId,
      ).toJson(),
    ),
  );

  if (result.hasException) {
    throw result.exception!;
  }

  await invalidator.invalidate(InvalidationRules.continueWatchingRemoved());
}

/// Runs [remove] and reports a failure, for the two screens that offer the
/// action. Shared so the wording cannot drift between them.
///
/// Success is silent on purpose. The card disappearing is the confirmation,
/// and there is no undo to offer in a snackbar: hiding is reversed by playing
/// the title, the way Plex does it.
Future<void> reportRemovalFailure(
  BuildContext context,
  Future<void> Function() remove,
) async {
  // Captured before the await. The card is being removed from under this
  // context, and on the home rail the widget it belongs to is gone by the time
  // the mutation answers.
  final messenger = ScaffoldMessenger.of(context);

  try {
    await remove();
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Could not remove from Continue Watching'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
