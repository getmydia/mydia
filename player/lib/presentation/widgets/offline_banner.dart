import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/graphql/graphql_provider.dart';
import '../../core/theme/colors.dart';
import 'banner_button.dart';

/// Banner displayed at the top of the screen when the app is in offline mode.
///
/// Shows a message indicating offline status and provides a "Retry Connection"
/// button to attempt reconnecting to the server.
class OfflineBanner extends ConsumerStatefulWidget {
  const OfflineBanner({super.key});

  @override
  ConsumerState<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends ConsumerState<OfflineBanner> {
  bool _isRetrying = false;

  Future<void> _retryConnection() async {
    setState(() => _isRetrying = true);

    try {
      await ref.read(authStateProvider.notifier).retryConnection();
    } finally {
      if (mounted) {
        setState(() => _isRetrying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.15),
        border: Border(
          bottom: BorderSide(
            color: AppColors.warning.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 18,
              color: AppColors.warning,
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                "You're offline - only downloads available",
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.warning,
                ),
              ),
            ),
            const SizedBox(width: 12),
            BannerButton(
              label: 'Retry',
              color: AppColors.warning,
              isLoading: _isRetrying,
              onPressed: _retryConnection,
            ),
          ],
        ),
      ),
    );
  }
}
