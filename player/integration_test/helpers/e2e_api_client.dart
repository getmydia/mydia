import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// API client for E2E test setup operations.
///
/// This client is used to interact with the Mydia GraphQL API
/// for test setup operations like authentication and claim code generation.
class E2eApiClient {
  final String mydiaUrl;
  final String adminEmail;
  final String adminPassword;

  String? _authToken;

  /// The current auth token (if logged in).
  String? get authToken => _authToken;

  E2eApiClient({
    required this.mydiaUrl,
    required this.adminEmail,
    required this.adminPassword,
  });

  /// Creates an E2eApiClient from environment variables.
  ///
  /// Environment variables (runtime):
  /// - MYDIA_URL: Base URL of the Mydia server (e.g., http://mydia:4000)
  /// - E2E_ADMIN_EMAIL: Admin user email
  /// - E2E_ADMIN_PASSWORD: Admin user password
  ///
  /// Note: Uses Platform.environment for runtime access since the test driver
  /// runs on the host machine, not in the browser. Compile-time String.fromEnvironment
  /// would not work for the driver code.
  factory E2eApiClient.fromEnvironment() {
    // Use runtime environment variables - the test driver runs on the host
    final mydiaUrl = Platform.environment['MYDIA_URL'] ?? 'http://mydia:4000';
    final adminEmail =
        Platform.environment['E2E_ADMIN_EMAIL'] ?? 'admin@test.local';
    final adminPassword =
        Platform.environment['E2E_ADMIN_PASSWORD'] ?? 'testpassword123';

    return E2eApiClient(
      mydiaUrl: mydiaUrl,
      adminEmail: adminEmail,
      adminPassword: adminPassword,
    );
  }

  /// Login as admin and store the auth token.
  Future<void> login() async {
    const query = '''
      mutation Login(\$input: LoginInput!) {
        login(input: \$input) {
          token
          expiresIn
        }
      }
    ''';

    final variables = {
      'input': {
        'username': adminEmail,
        'password': adminPassword,
        'deviceId': 'e2e-test-device',
        'deviceName': 'E2E Test Runner',
        'platform': 'web',
      },
    };

    final response = await graphqlRequest(query, variables);

    if (response['errors'] != null) {
      final errors = response['errors'] as List;
      throw Exception('Login failed: ${errors.first['message']}');
    }

    _authToken = response['data']['login']['token'] as String;
  }

  /// Generate a claim code for device pairing.
  ///
  /// Must call [login] first to authenticate.
  Future<ClaimCodeResult> generateClaimCode() async {
    if (_authToken == null) {
      throw StateError('Not authenticated. Call login() first.');
    }

    const query = '''
      mutation GenerateClaimCode {
        generateClaimCode {
          code
          expiresAt
        }
      }
    ''';

    final response = await graphqlRequest(query, {});

    if (response['errors'] != null) {
      final errors = response['errors'] as List;
      throw Exception(
          'Failed to generate claim code: ${errors.first['message']}');
    }

    final data = response['data']['generateClaimCode'];
    return ClaimCodeResult(
      code: data['code'] as String,
      expiresAt: DateTime.parse(data['expiresAt'] as String),
    );
  }

  /// Perform a GraphQL request.
  Future<Map<String, dynamic>> graphqlRequest(
    String query,
    Map<String, dynamic> variables,
  ) async {
    final uri = Uri.parse('$mydiaUrl/api/graphql');

    final headers = <String, String>{
      'Content-Type': 'application/json',
    };

    if (_authToken != null) {
      headers['Authorization'] = 'Bearer $_authToken';
    }

    final body = jsonEncode({
      'query': query,
      'variables': variables,
    });

    final response = await http.post(uri, headers: headers, body: body);

    if (response.statusCode != 200) {
      throw Exception(
        'GraphQL request failed with status ${response.statusCode}: ${response.body}',
      );
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Check if the Mydia server is healthy.
  Future<bool> isHealthy() async {
    try {
      final uri = Uri.parse('$mydiaUrl/health');
      final response = await http.get(uri);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Wait for Mydia server to become healthy.
  Future<void> waitForHealthy({
    Duration timeout = const Duration(seconds: 60),
    Duration interval = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      if (await isHealthy()) {
        return;
      }
      await Future.delayed(interval);
    }

    throw TimeoutException(
        'Mydia server did not become healthy within $timeout');
  }
}

/// Result of generating a claim code.
class ClaimCodeResult {
  final String code;
  final DateTime expiresAt;

  ClaimCodeResult({required this.code, required this.expiresAt});

  /// Returns the code formatted for display (e.g., "ABC-XYZ").
  String get formattedCode => code;

  /// Check if the code has expired.
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  @override
  String toString() => 'ClaimCodeResult(code: $code, expiresAt: $expiresAt)';
}

/// Exception thrown when an operation times out.
class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);

  @override
  String toString() => 'TimeoutException: $message';
}
