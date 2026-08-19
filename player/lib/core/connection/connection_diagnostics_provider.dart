/// Connection diagnostics provider for displaying connection status in settings.
///
/// This provider aggregates connection information from various sources:
/// - Direct URLs from stored credentials
/// - Connection attempt results and errors
/// - Last probe timestamps
///
/// Used by the settings screen to show detailed connection diagnostics.
library;

import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_storage.dart';
import '../format/relative_time.dart';
import 'connection_provider.dart';

/// Storage keys for diagnostics.
abstract class _DiagnosticsKeys {
  static const lastDirectAttempt = 'diagnostics_last_direct_attempt';
  static const directUrlErrors = 'diagnostics_direct_url_errors';
}

/// Erases stored connection diagnostics.
///
/// Called from sign-out teardown: the recorded attempts include the
/// server's direct URLs, which should not outlive the session that
/// produced them.
Future<void> clearConnectionDiagnostics(AuthStorage storage) async {
  // Concurrent, not sequential: one refused delete must not strand the
  // other key.
  await Future.wait([
    storage.delete(_DiagnosticsKeys.lastDirectAttempt),
    storage.delete(_DiagnosticsKeys.directUrlErrors),
  ]);
}

/// Simple result type for URL attempts.
class UrlProbeResult {
  final String url;
  final bool success;
  final String? error;
  final DateTime timestamp;

  const UrlProbeResult({
    required this.url,
    required this.success,
    this.error,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'success': success,
        'error': error,
        'timestamp': timestamp.toIso8601String(),
      };

  factory UrlProbeResult.fromJson(Map<String, dynamic> json) => UrlProbeResult(
        url: json['url'] as String,
        success: json['success'] as bool,
        error: json['error'] as String?,
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}

/// Re-export for convenience in UI.
typedef DirectUrlAttempt = UrlProbeResult;

/// Connection diagnostics state.
class ConnectionDiagnosticsState {
  /// List of direct URLs configured for this instance.
  final List<String> directUrls;

  /// Last connection attempt results for each URL.
  final Map<String, DirectUrlAttempt> urlAttempts;

  /// When direct connection was last attempted.
  final DateTime? lastDirectAttempt;

  /// Whether currently connected via P2P.
  final bool isP2PMode;

  /// Whether diagnostics are still loading.
  final bool isLoading;

  const ConnectionDiagnosticsState({
    this.directUrls = const [],
    this.urlAttempts = const {},
    this.lastDirectAttempt,
    this.isP2PMode = false,
    this.isLoading = true,
  });

  ConnectionDiagnosticsState copyWith({
    List<String>? directUrls,
    Map<String, DirectUrlAttempt>? urlAttempts,
    DateTime? lastDirectAttempt,
    bool? isP2PMode,
    bool? isLoading,
    bool clearLastDirectAttempt = false,
  }) {
    return ConnectionDiagnosticsState(
      directUrls: directUrls ?? this.directUrls,
      urlAttempts: urlAttempts ?? this.urlAttempts,
      lastDirectAttempt: clearLastDirectAttempt
          ? null
          : (lastDirectAttempt ?? this.lastDirectAttempt),
      isP2PMode: isP2PMode ?? this.isP2PMode,
      isLoading: isLoading ?? this.isLoading,
    );
  }

  /// Gets the attempt result for a specific URL.
  DirectUrlAttempt? getAttempt(String url) => urlAttempts[url];

  /// Whether all direct URLs have failed.
  bool get allDirectUrlsFailed =>
      directUrls.isNotEmpty &&
      urlAttempts.length == directUrls.length &&
      urlAttempts.values.every((a) => !a.success);

  /// Gets a human-readable time since last attempt.
  String? get timeSinceLastAttempt {
    if (lastDirectAttempt == null) return null;
    return formatRelativeTime(lastDirectAttempt!);
  }
}

/// Notifier for connection diagnostics.
class ConnectionDiagnosticsNotifier
    extends Notifier<ConnectionDiagnosticsState> {
  @override
  ConnectionDiagnosticsState build() {
    // Watch the connection provider for real-time updates
    final connectionState = ref.watch(connectionProvider);

    // Schedule async load
    Future.microtask(_loadDiagnostics);

    return ConnectionDiagnosticsState(
      isP2PMode: connectionState.isP2PMode,
      isLoading: true,
    );
  }

  AuthStorage get _authStorage => getAuthStorage();

  /// Loads diagnostics from storage and credentials.
  Future<void> _loadDiagnostics() async {
    try {
      // Load direct URLs from stored credentials
      final directUrlsJson = await _authStorage.read('pairing_direct_urls');
      List<String> directUrls = [];
      if (directUrlsJson != null) {
        try {
          final decoded = jsonDecode(directUrlsJson);
          if (decoded is List) {
            directUrls = decoded.cast<String>();
          }
        } catch (e) {
          debugPrint('[ConnectionDiagnostics] Failed to parse direct URLs: $e');
        }
      }

      // Load last direct attempt timestamp
      DateTime? lastDirectAttempt;
      final lastAttemptStr =
          await _authStorage.read(_DiagnosticsKeys.lastDirectAttempt);
      if (lastAttemptStr != null) {
        try {
          lastDirectAttempt = DateTime.parse(lastAttemptStr);
        } catch (e) {
          debugPrint(
              '[ConnectionDiagnostics] Failed to parse last attempt: $e');
        }
      }

      // Load URL attempt errors
      Map<String, DirectUrlAttempt> urlAttempts = {};
      final errorsJson =
          await _authStorage.read(_DiagnosticsKeys.directUrlErrors);
      if (errorsJson != null) {
        try {
          final decoded = jsonDecode(errorsJson) as Map<String, dynamic>;
          urlAttempts = decoded.map((key, value) => MapEntry(
              key, DirectUrlAttempt.fromJson(value as Map<String, dynamic>)));
        } catch (e) {
          debugPrint('[ConnectionDiagnostics] Failed to parse URL errors: $e');
        }
      }

      // Get current connection state
      final connectionState = ref.read(connectionProvider);

      state = ConnectionDiagnosticsState(
        directUrls: directUrls,
        urlAttempts: urlAttempts,
        lastDirectAttempt: lastDirectAttempt,
        isP2PMode: connectionState.isP2PMode,
        isLoading: false,
      );
    } catch (e) {
      debugPrint('[ConnectionDiagnostics] Error loading diagnostics: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  /// Records a direct URL connection attempt.
  Future<void> recordAttempt({
    required String url,
    required bool success,
    String? error,
  }) async {
    final attempt = DirectUrlAttempt(
      url: url,
      success: success,
      error: error,
      timestamp: DateTime.now(),
    );

    final newAttempts = Map<String, DirectUrlAttempt>.from(state.urlAttempts);
    newAttempts[url] = attempt;

    // Save to storage
    await _authStorage.write(
      _DiagnosticsKeys.directUrlErrors,
      jsonEncode(newAttempts.map((k, v) => MapEntry(k, v.toJson()))),
    );

    // Update last attempt time
    await _authStorage.write(
      _DiagnosticsKeys.lastDirectAttempt,
      DateTime.now().toIso8601String(),
    );

    state = state.copyWith(
      urlAttempts: newAttempts,
      lastDirectAttempt: DateTime.now(),
    );
  }

  /// Records multiple URL attempts at once.
  Future<void> recordBatchAttempts(List<DirectUrlAttempt> attempts) async {
    final newAttempts = Map<String, DirectUrlAttempt>.from(state.urlAttempts);
    for (final attempt in attempts) {
      newAttempts[attempt.url] = attempt;
    }

    // Save to storage
    await _authStorage.write(
      _DiagnosticsKeys.directUrlErrors,
      jsonEncode(newAttempts.map((k, v) => MapEntry(k, v.toJson()))),
    );

    // Update last attempt time
    await _authStorage.write(
      _DiagnosticsKeys.lastDirectAttempt,
      DateTime.now().toIso8601String(),
    );

    state = state.copyWith(
      urlAttempts: newAttempts,
      lastDirectAttempt: DateTime.now(),
    );
  }

  /// Clears all diagnostic data.
  Future<void> clear() async {
    await _authStorage.delete(_DiagnosticsKeys.lastDirectAttempt);
    await _authStorage.delete(_DiagnosticsKeys.directUrlErrors);
    state = const ConnectionDiagnosticsState(isLoading: false);
  }

  /// Refreshes diagnostics from storage.
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true);
    await _loadDiagnostics();
  }
}

/// Provider for connection diagnostics.
final connectionDiagnosticsProvider =
    NotifierProvider<ConnectionDiagnosticsNotifier, ConnectionDiagnosticsState>(
        ConnectionDiagnosticsNotifier.new);
