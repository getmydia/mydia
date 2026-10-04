library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/source.dart';
import '../../../domain/sources/source_error.dart';

class SourceErrorView extends StatelessWidget {
  const SourceErrorView({
    super.key,
    required this.error,
    required this.onRetry,
    this.account,
  });

  final Object error;
  final VoidCallback onRetry;

  /// When given and the error is a refused credential, offers to sign in
  /// again instead of retrying.
  final ProviderAccount? account;

  @override
  Widget build(BuildContext context) {
    final sourceError =
        error is SourceException ? error as SourceException : null;
    final unauthorized = sourceError?.kind == SourceErrorKind.unauthorized;
    final account = this.account;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(unauthorized ? Icons.lock_outline : Icons.cloud_off, size: 48),
            const SizedBox(height: 16),
            Text(
              sourceError?.viewerMessage ?? 'Something went wrong.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (unauthorized && account != null)
              FilledButton(
                key: const Key('source-error-sign-in'),
                autofocus: true,
                onPressed: () => context.push(
                    '/sources/add/${account.kind.name}?account=${account.id}'),
                child: const Text('Sign in again'),
              )
            else
              FilledButton(
                key: const Key('source-error-retry'),
                autofocus: true,
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
          ],
        ),
      ),
    );
  }
}
