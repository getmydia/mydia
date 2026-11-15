import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import '../../auth/auth_storage.dart';
import '../../player/input_capabilities.dart';
import '../../player/platform_features.dart';
import '../backup_relay_client.dart';

/// [AuthStorage] key of the Google Drive grant: JSON with `email`, and on
/// desktop and TV also `refreshToken` and `clientKind`.
const String googleDriveStorageKey = 'backup/gdrive';

/// The only Drive scope the backup uses: a hidden per-app folder.
const String googleDriveAppDataScope =
    'https://www.googleapis.com/auth/drive.appdata';

/// Scopes of the OAuth flows. `openid email` only so the token response
/// carries an `id_token` naming the account for the status line.
const List<String> googleOAuthScopes = <String>[
  'openid',
  'email',
  googleDriveAppDataScope,
];

final Uri googleAuthEndpoint =
    Uri.parse('https://accounts.google.com/o/oauth2/v2/auth');
final Uri googleTokenEndpoint =
    Uri.parse('https://oauth2.googleapis.com/token');
final Uri googleDeviceCodeEndpoint =
    Uri.parse('https://oauth2.googleapis.com/device/code');
final Uri googleRevokeEndpoint =
    Uri.parse('https://oauth2.googleapis.com/revoke');

/// Where [GoogleSignInAuth] reads the account email, since the plugin's
/// authorization result carries only an access token.
final Uri googleUserInfoEndpoint =
    Uri.parse('https://openidconnect.googleapis.com/v1/userinfo');

/// A signed-in Google account that hands out Drive access tokens.
abstract class GoogleAuth {
  /// The signed-in account's email, or null when signed out.
  Future<String?> currentEmail();

  /// A bearer token for [googleDriveAppDataScope]. [forceRefresh] skips any
  /// cached token, for a caller whose request just came back 401.
  ///
  /// Throws [BackupRelayException] with [BackupRelayError.signedOut] when no
  /// account is signed in or its grant was revoked.
  Future<String> accessToken({bool forceRefresh = false});

  /// Forgets the account and revokes its grant where possible.
  Future<void> signOut();
}

/// The token endpoint's answer: HTTP status and the decoded JSON body (empty
/// when the body is not a JSON object).
class GoogleOAuthResponse {
  const GoogleOAuthResponse(this.status, this.json);

  final int status;
  final Map<String, Object?> json;

  String? get error => json['error'] as String?;
}

/// Google OAuth for clients holding their own refresh token: desktop
/// (`LoopbackPkceFlow`) and Android TV (`DeviceCodeFlow`).
///
/// The flows obtain the first grant and hand it to [completeSignIn]; from
/// then on this refreshes access tokens from the stored refresh token.
class GoogleTokenAuth implements GoogleAuth {
  GoogleTokenAuth({
    required AuthStorage storage,
    required http.Client client,
    required this.clientId,
    required this.clientSecret,
    this.clientKind = 'desktop',
    DateTime Function()? now,
  })  : _storage = storage,
        _client = client,
        _now = now ?? DateTime.now;

  final AuthStorage _storage;
  final http.Client _client;
  final DateTime Function() _now;

  final String clientId;

  /// An installed-app secret. Google requires it at the token endpoint for
  /// desktop and TV clients but does not treat it as confidential.
  final String clientSecret;

  /// `desktop` or `tv`, stored with the grant so a refresh token is never
  /// sent with the other client's id.
  final String clientKind;

  /// Margin before the stated expiry at which a cached token is dropped.
  static const Duration _expirySkew = Duration(seconds: 60);

  String? _accessToken;
  DateTime? _accessExpiry;
  Future<String>? _refreshing;

  @override
  Future<String?> currentEmail() async => (await _readGrant())?['email'];

  @override
  Future<String> accessToken({bool forceRefresh = false}) {
    final cached = _accessToken;
    final expiry = _accessExpiry;
    if (!forceRefresh &&
        cached != null &&
        expiry != null &&
        _now().isBefore(expiry.subtract(_expirySkew))) {
      return Future.value(cached);
    }
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String> _refresh() async {
    final grant = await _readGrant();
    final refreshToken = grant?['refreshToken'];
    if (refreshToken == null || grant?['clientKind'] != clientKind) {
      throw const BackupRelayException(BackupRelayError.signedOut);
    }
    final res = await postForm(googleTokenEndpoint, {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
      'client_secret': clientSecret,
    });
    if (res.status != 200) {
      if (res.error == 'invalid_grant') {
        // Revoked, expired, or the password changed: the grant is dead.
        _clearCache();
        await _storage.delete(googleDriveStorageKey);
        throw const BackupRelayException(
          BackupRelayError.signedOut,
          code: 'invalid_grant',
        );
      }
      throw oauthError(res);
    }
    return _cacheAccess(res.json);
  }

  /// Stores the grant of a finished sign-in flow and returns its email.
  ///
  /// Google rotates refresh tokens only sometimes, so a grant without one
  /// keeps the stored token.
  Future<String> completeSignIn(Map<String, Object?> grant) async {
    final stored = await _readGrant();
    // Never carry a token or email over from the other client's grant.
    final existing = stored?['clientKind'] == clientKind ? stored : null;
    final refreshToken =
        grant['refresh_token'] as String? ?? existing?['refreshToken'];
    final email = _emailFromIdToken(grant['id_token']) ?? existing?['email'];
    if (refreshToken == null) {
      throw const BackupRelayException(
        BackupRelayError.signedOut,
        code: 'no_refresh_token',
      );
    }
    if (email == null) {
      throw const FormatException('token response names no account');
    }
    await _storage.write(
      googleDriveStorageKey,
      jsonEncode({
        'email': email,
        'refreshToken': refreshToken,
        'clientKind': clientKind,
      }),
    );
    _cacheAccess(grant);
    return email;
  }

  @override
  Future<void> signOut() async {
    final refreshToken = (await _readGrant())?['refreshToken'];
    _clearCache();
    await _storage.delete(googleDriveStorageKey);
    if (refreshToken == null) return;
    try {
      await postForm(googleRevokeEndpoint, {'token': refreshToken});
    } on BackupRelayException {
      // Signing out is local first; an unreachable revoke leaves a grant
      // the user can still remove from their Google account page.
    }
  }

  /// POSTs a form to a Google OAuth endpoint. Transport failures become
  /// [BackupRelayError.network]; HTTP errors are returned for the caller to
  /// read the OAuth `error` code.
  Future<GoogleOAuthResponse> postForm(
    Uri url,
    Map<String, String> form,
  ) async {
    final http.Response res;
    try {
      // A Map body is sent form-urlencoded.
      res = await _client
          .post(url, body: form)
          .timeout(const Duration(seconds: 30));
    } on http.ClientException {
      throw const BackupRelayException(BackupRelayError.network);
    } on TimeoutException {
      throw const BackupRelayException(BackupRelayError.network);
    }
    Map<String, Object?> json = const {};
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, Object?>) json = decoded;
    } on FormatException {
      // Not JSON: leave the body empty and let the status decide.
    }
    return GoogleOAuthResponse(res.statusCode, json);
  }

  /// The exception for an unexpected OAuth endpoint answer.
  BackupRelayException oauthError(GoogleOAuthResponse res) {
    final kind = switch (res.status) {
      429 => BackupRelayError.rateLimited,
      >= 500 => BackupRelayError.server,
      401 => BackupRelayError.unauthorized,
      _ => BackupRelayError.invalid,
    };
    return BackupRelayException(kind, code: res.error);
  }

  String _cacheAccess(Map<String, Object?> grant) {
    final token = grant['access_token'];
    if (token is! String) {
      throw const FormatException('token response has no access_token');
    }
    final expiresIn = (grant['expires_in'] as num?)?.toInt() ?? 3600;
    _accessToken = token;
    _accessExpiry = _now().add(Duration(seconds: expiresIn));
    return token;
  }

  void _clearCache() {
    _accessToken = null;
    _accessExpiry = null;
  }

  Future<Map<String, String>?> _readGrant() async {
    final raw = await _storage.read(googleDriveStorageKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      return {
        for (final e in decoded.entries)
          if (e.value is String) e.key: e.value as String,
      };
    } on FormatException {
      return null;
    }
  }
}

/// The `email` claim of an `id_token`.
///
/// Unverified on purpose: the token came straight from Google's token
/// endpoint over TLS, which OpenID Connect accepts in place of checking the
/// signature, and it only labels the account.
String? _emailFromIdToken(Object? idToken) {
  if (idToken is! String) return null;
  final parts = idToken.split('.');
  if (parts.length != 3) return null;
  try {
    final padded = parts[1].padRight((parts[1].length + 3) ~/ 4 * 4, '=');
    final claims = jsonDecode(utf8.decode(base64Url.decode(padded)));
    return claims is Map ? claims['email'] as String? : null;
  } on FormatException {
    return null;
  }
}

/// The google_sign_in calls [GoogleSignInAuth] makes, behind a seam so its
/// signed-out decision can be tested without the plugin. Methods throw the
/// plugin's [GoogleSignInException].
abstract class GoogleSignInBackend {
  /// Restores the previous session without UI. True when an account came
  /// back; false when there is none to restore.
  Future<bool> restoreSession();

  /// A token for [scopes] without UI, or null when the user must be asked.
  Future<String?> authorizationForScopes(List<String> scopes);

  /// A token for [scopes], showing the consent UI when needed.
  Future<String> authorizeScopes(List<String> scopes);

  Future<void> clearToken(String accessToken);

  Future<void> disconnect();
}

/// [GoogleSignInBackend] over `GoogleSignIn.instance`.
class PluginGoogleSignInBackend implements GoogleSignInBackend {
  PluginGoogleSignInBackend({this.clientId});

  /// The iOS client id. Null on Android, which identifies the app by its
  /// package name and signing certificate instead.
  final String? clientId;

  /// `GoogleSignIn.initialize` may run only once per process.
  static Future<void>? _initialized;

  /// The account [restoreSession] brought back, whose authorization client
  /// carries its id so iOS asks for that account's grant.
  GoogleSignInAccount? _account;

  Future<GoogleSignIn> _ready() async {
    await (_initialized ??=
        GoogleSignIn.instance.initialize(clientId: clientId));
    return GoogleSignIn.instance;
  }

  Future<GoogleSignInAuthorizationClient> _authz() async =>
      _account?.authorizationClient ?? (await _ready()).authorizationClient;

  @override
  Future<bool> restoreSession() async {
    final attempt = (await _ready()).attemptLightweightAuthentication();
    // A null future means the platform reports sign-ins only through the
    // event stream (the web); there is nothing to wait for here.
    final account = attempt == null ? null : await attempt;
    if (account != null) _account = account;
    return account != null;
  }

  @override
  Future<String?> authorizationForScopes(List<String> scopes) async =>
      (await (await _authz()).authorizationForScopes(scopes))?.accessToken;

  @override
  Future<String> authorizeScopes(List<String> scopes) async =>
      (await (await _authz()).authorizeScopes(scopes)).accessToken;

  @override
  Future<void> clearToken(String accessToken) async =>
      (await _authz()).clearAuthorizationToken(accessToken: accessToken);

  @override
  Future<void> disconnect() async {
    _account = null;
    await (await _ready()).disconnect();
  }
}

/// Google sign-in through the platform SDK, on Android phones and iOS.
///
/// The plugin keeps the grant and its tokens; [googleDriveStorageKey] holds
/// only `email`, for [currentEmail] to answer without the plugin.
class GoogleSignInAuth implements GoogleAuth {
  GoogleSignInAuth({
    required AuthStorage storage,
    required http.Client client,
    String? clientId,
    GoogleSignInBackend? backend,
  })  : _storage = storage,
        _client = client,
        _backend = backend ?? PluginGoogleSignInBackend(clientId: clientId);

  final AuthStorage _storage;
  final http.Client _client;
  final GoogleSignInBackend _backend;

  String? _lastToken;

  /// Whether this process has restored the plugin's session. After a cold
  /// start iOS has no current user until it does, so a no-UI authorization
  /// before it would read as signed out.
  bool _restored = false;

  /// Why the last restore failed, if it did. While set, a null authorization
  /// is not proof of a sign-out.
  GoogleSignInException? _restoreError;

  /// Asks the user to grant Drive access; call from a button press. Returns
  /// the account email.
  Future<String> signIn() async {
    final String token;
    try {
      token = await _backend.authorizeScopes(googleOAuthScopes);
    } on GoogleSignInException catch (e) {
      throw _mapException(e);
    }
    _lastToken = token;
    _restored = true;
    _restoreError = null;
    final email = await _fetchEmail(token);
    await _storage.write(googleDriveStorageKey, jsonEncode({'email': email}));
    return email;
  }

  @override
  Future<String?> currentEmail() async {
    final raw = await _storage.read(googleDriveStorageKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded['email'] as String? : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<String> accessToken({bool forceRefresh = false}) async {
    if (await currentEmail() == null) {
      throw const BackupRelayException(BackupRelayError.signedOut);
    }
    if (!_restored) {
      try {
        await _backend.restoreSession();
        _restored = true;
        _restoreError = null;
      } on GoogleSignInException catch (e) {
        // Android may refuse a lightweight sign-in it does not need for
        // authorization; try the grant anyway and keep the reason.
        _restoreError = e;
      }
    }
    final String? token;
    try {
      final stale = _lastToken;
      if (forceRefresh && stale != null) {
        await _backend.clearToken(stale);
      }
      token = await _backend.authorizationForScopes(googleOAuthScopes);
    } on GoogleSignInException catch (e) {
      throw _mapException(e);
    }
    if (token != null) return _lastToken = token;
    final restoreError = _restoreError;
    if (restoreError != null) {
      // No session, but only because restoring it failed: not a sign-out.
      throw _mapException(restoreError);
    }
    // Restored (or nothing to restore) and still no grant: revoked, or the
    // account was removed from the device.
    await _storage.delete(googleDriveStorageKey);
    throw const BackupRelayException(BackupRelayError.signedOut);
  }

  @override
  Future<void> signOut() async {
    _lastToken = null;
    await _storage.delete(googleDriveStorageKey);
    try {
      await _backend.disconnect();
    } on GoogleSignInException {
      // Local sign-out already happened; the grant stays listed on the
      // user's Google account page.
    }
  }

  Future<String> _fetchEmail(String accessToken) async {
    final http.Response res;
    try {
      res = await _client.get(
        googleUserInfoEndpoint,
        headers: {'authorization': 'Bearer $accessToken'},
      ).timeout(const Duration(seconds: 30));
    } on http.ClientException {
      throw const BackupRelayException(BackupRelayError.network);
    } on TimeoutException {
      throw const BackupRelayException(BackupRelayError.network);
    }
    if (res.statusCode != 200) {
      throw BackupRelayException(
        res.statusCode >= 500
            ? BackupRelayError.server
            : BackupRelayError.unauthorized,
      );
    }
    Object? body;
    try {
      body = jsonDecode(res.body);
    } on FormatException {
      body = null;
    }
    final email = body is Map ? body['email'] : null;
    if (email is! String) {
      throw const BackupRelayException(
        BackupRelayError.server,
        code: 'userinfo_malformed',
      );
    }
    return email;
  }

  /// Maps a plugin failure. Only a user cancel means signed out; an
  /// interrupted call is transient, anything else a platform failure. None
  /// of them clears the stored account.
  BackupRelayException _mapException(GoogleSignInException e) =>
      BackupRelayException(
        switch (e.code) {
          GoogleSignInExceptionCode.canceled => BackupRelayError.signedOut,
          GoogleSignInExceptionCode.interrupted => BackupRelayError.network,
          _ => BackupRelayError.server,
        },
        code: e.code.name,
      );
}

/// The platforms [googleFlowFor] distinguishes.
enum GoogleTargetPlatform { android, ios, desktop, web }

/// Which sign-in a platform uses.
enum GoogleFlowKind {
  /// [GoogleSignInAuth]: Android phones and iOS.
  signIn,

  /// `LoopbackPkceFlow` over [GoogleTokenAuth]: macOS, Linux, Windows.
  loopback,

  /// `DeviceCodeFlow` over [GoogleTokenAuth]: Android TV.
  deviceCode,
}

/// The OAuth client ids and installed-app secrets, from `--dart-define`.
class GoogleClientDefines {
  const GoogleClientDefines({
    required this.android,
    required this.ios,
    required this.desktop,
    required this.desktopSecret,
    required this.tv,
    required this.tvSecret,
  });

  static const GoogleClientDefines fromEnvironment = GoogleClientDefines(
    android: String.fromEnvironment('MYDIA_GDRIVE_CLIENT_ID_ANDROID'),
    ios: String.fromEnvironment('MYDIA_GDRIVE_CLIENT_ID_IOS'),
    desktop: String.fromEnvironment('MYDIA_GDRIVE_CLIENT_ID_DESKTOP'),
    desktopSecret: String.fromEnvironment('MYDIA_GDRIVE_CLIENT_SECRET_DESKTOP'),
    tv: String.fromEnvironment('MYDIA_GDRIVE_CLIENT_ID_TV'),
    tvSecret: String.fromEnvironment('MYDIA_GDRIVE_CLIENT_SECRET_TV'),
  );

  final String android;
  final String ios;
  final String desktop;
  final String desktopSecret;
  final String tv;
  final String tvSecret;
}

/// The sign-in flow for a platform, or null when Google Drive is hidden
/// there: on the web, or when that platform's define is empty.
@visibleForTesting
GoogleFlowKind? googleFlowFor({
  required GoogleTargetPlatform platform,
  required bool directionalPrimary,
  required GoogleClientDefines defines,
}) {
  switch (platform) {
    case GoogleTargetPlatform.web:
      return null;
    case GoogleTargetPlatform.android when directionalPrimary:
      return defines.tv.isEmpty || defines.tvSecret.isEmpty
          ? null
          : GoogleFlowKind.deviceCode;
    case GoogleTargetPlatform.android:
      return defines.android.isEmpty ? null : GoogleFlowKind.signIn;
    case GoogleTargetPlatform.ios:
      return defines.ios.isEmpty ? null : GoogleFlowKind.signIn;
    case GoogleTargetPlatform.desktop:
      return defines.desktop.isEmpty || defines.desktopSecret.isEmpty
          ? null
          : GoogleFlowKind.loopback;
  }
}

/// The [GoogleAuth] for this device, or null when Google Drive is hidden.
///
/// The caller picks the sign-in UI from the result: [GoogleSignInAuth.signIn]
/// directly, or for a [GoogleTokenAuth] `LoopbackPkceFlow` when its
/// [GoogleTokenAuth.clientKind] is `desktop` and `DeviceCodeFlow` when `tv`.
GoogleAuth? googleAuthForPlatform(AuthStorage s, {http.Client? client}) {
  final GoogleTargetPlatform platform;
  if (kIsWeb) {
    platform = GoogleTargetPlatform.web;
  } else if (PlatformFeatures.isAndroid) {
    platform = GoogleTargetPlatform.android;
  } else if (PlatformFeatures.isIOS) {
    platform = GoogleTargetPlatform.ios;
  } else if (PlatformFeatures.isDesktop) {
    platform = GoogleTargetPlatform.desktop;
  } else {
    return null;
  }
  const defines = GoogleClientDefines.fromEnvironment;
  final kind = googleFlowFor(
    platform: platform,
    directionalPrimary: InputCapabilities.directionalPrimary,
    defines: defines,
  );
  final http.Client c = client ?? http.Client();
  return switch (kind) {
    null => null,
    GoogleFlowKind.signIn => GoogleSignInAuth(
        storage: s,
        client: c,
        clientId: platform == GoogleTargetPlatform.ios ? defines.ios : null,
      ),
    GoogleFlowKind.loopback => GoogleTokenAuth(
        storage: s,
        client: c,
        clientId: defines.desktop,
        clientSecret: defines.desktopSecret,
      ),
    GoogleFlowKind.deviceCode => GoogleTokenAuth(
        storage: s,
        client: c,
        clientId: defines.tv,
        clientSecret: defines.tvSecret,
        clientKind: 'tv',
      ),
  };
}
