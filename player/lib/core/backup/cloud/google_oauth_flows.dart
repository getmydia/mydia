import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/current_l10n.dart';
import '../backup_relay_client.dart';
import 'google_auth.dart';

String _b64NoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Desktop sign-in (macOS, Linux, Windows): the system browser, a one-shot
/// HTTP listener on `127.0.0.1` for the redirect, and PKCE.
class LoopbackPkceFlow {
  LoopbackPkceFlow({
    Random? random,
    this.timeout = const Duration(minutes: 5),
  }) : _random = random ?? Random.secure();

  final Random _random;

  /// How long the listener waits for the browser to come back.
  final Duration timeout;

  /// A PKCE verifier: 64 random bytes, base64url without padding.
  @visibleForTesting
  static String newVerifier(Random random) =>
      _b64NoPad(List<int>.generate(64, (_) => random.nextInt(256)));

  /// The S256 challenge of [verifier].
  @visibleForTesting
  static String challengeFor(String verifier) =>
      _b64NoPad(sha256.convert(ascii.encode(verifier)).bytes);

  /// Opens the consent page with [launch] and stores the resulting grant in
  /// [auth]. Throws [BackupRelayException]: [BackupRelayError.signedOut] when
  /// the user declines or never returns within [timeout]. A redirect whose
  /// `state` is not ours is answered with an error page and ignored.
  Future<void> signIn(
    GoogleTokenAuth auth, {
    Future<bool> Function(Uri) launch = launchUrl,
  }) async {
    final verifier = newVerifier(_random);
    final state =
        _b64NoPad(List<int>.generate(16, (_) => _random.nextInt(256)));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirectUri = 'http://127.0.0.1:${server.port}';
      final url = googleAuthEndpoint.replace(
        queryParameters: {
          'client_id': auth.clientId,
          'redirect_uri': redirectUri,
          'response_type': 'code',
          'scope': googleOAuthScopes.join(' '),
          'code_challenge': challengeFor(verifier),
          'code_challenge_method': 'S256',
          'state': state,
          // A refresh token on every consent, including a repeat one.
          'access_type': 'offline',
          'prompt': 'consent',
        },
      );
      if (!await launch(url)) {
        throw const BackupRelayException(
          BackupRelayError.cloudUnavailable,
          code: 'launch_failed',
        );
      }
      final params = await _awaitRedirect(server, state).timeout(
        timeout,
        onTimeout: () => throw const BackupRelayException(
          BackupRelayError.signedOut,
          code: 'timeout',
        ),
      );
      final error = params['error'];
      if (error != null) {
        throw BackupRelayException(
          error == 'access_denied'
              ? BackupRelayError.signedOut
              : BackupRelayError.invalid,
          code: error,
        );
      }
      final res = await auth.postForm(googleTokenEndpoint, {
        'grant_type': 'authorization_code',
        'code': params['code']!,
        'code_verifier': verifier,
        'redirect_uri': redirectUri,
        'client_id': auth.clientId,
        'client_secret': auth.clientSecret,
      });
      if (res.status != 200) throw auth.oauthError(res);
      await auth.completeSignIn(res.json);
    } finally {
      await server.close(force: true);
    }
  }

  /// The query of the first request that carries `code` or `error` with our
  /// [state]. Other requests, such as the browser's favicon fetch, get a
  /// 404; one with a foreign `state` gets a 400 and is ignored, so a forged
  /// redirect can neither sign in nor end the real one.
  Future<Map<String, String>> _awaitRedirect(
    HttpServer server,
    String state,
  ) async {
    await for (final req in server) {
      final params = req.uri.queryParameters;
      final res = req.response;
      if (!params.containsKey('code') && !params.containsKey('error')) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        continue;
      }
      final l10n = currentAppLocalizations();
      const esc = HtmlEscape();
      if (params['state'] != state) {
        res.statusCode = HttpStatus.badRequest;
        res.headers.contentType = ContentType.html;
        res.write(
          '<!doctype html><meta charset="utf-8"><title>Mydia</title>'
          '<p>${esc.convert(l10n.googleSignInBrowserStateMismatch)}</p>',
        );
        await res.close();
        continue;
      }
      res.headers.contentType = ContentType.html;
      res.write(
        '<!doctype html><meta charset="utf-8"><title>Mydia</title>'
        '<p>${esc.convert(l10n.googleSignInBrowserDone)}</p>',
      );
      await res.close();
      return params;
    }
    throw const BackupRelayException(BackupRelayError.signedOut);
  }
}

/// A step of [DeviceCodeFlow.signIn].
sealed class DeviceCodeState {
  const DeviceCodeState();
}

/// Show [userCode] and [verificationUrl] until [expiresAt].
class DeviceCodePending extends DeviceCodeState {
  const DeviceCodePending({
    required this.userCode,
    required this.verificationUrl,
    required this.expiresAt,
  });

  final String userCode;
  final Uri verificationUrl;
  final DateTime expiresAt;
}

/// Signed in as [email].
class DeviceCodeDone extends DeviceCodeState {
  const DeviceCodeDone(this.email);

  final String email;
}

/// The user declined on their other device.
class DeviceCodeDenied extends DeviceCodeState {
  const DeviceCodeDenied();
}

/// The code ran out before the user finished.
class DeviceCodeExpired extends DeviceCodeState {
  const DeviceCodeExpired();
}

/// Android TV sign-in: the TV shows a code, the user enters it on a phone or
/// computer, and the TV polls the token endpoint until they finish.
class DeviceCodeFlow {
  DeviceCodeFlow({
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
  })  : _delay = delay ?? Future<void>.delayed,
        _now = now ?? DateTime.now;

  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;

  static const Duration _slowDownStep = Duration(seconds: 5);

  /// Emits one [DeviceCodePending], then exactly one of [DeviceCodeDone],
  /// [DeviceCodeDenied] or [DeviceCodeExpired], then closes. A refused
  /// device-code request or an unexpected token error ends the stream with
  /// a [BackupRelayException].
  Stream<DeviceCodeState> signIn(GoogleTokenAuth auth) {
    var cancelled = false;
    final done = Completer<void>();
    late final StreamController<DeviceCodeState> controller;

    Future<void> run() async {
      try {
        final start = await auth.postForm(googleDeviceCodeEndpoint, {
          'client_id': auth.clientId,
          'scope': googleOAuthScopes.join(' '),
        });
        if (cancelled) return;
        if (start.status != 200) throw auth.oauthError(start);
        final json = start.json;
        final deviceCode = json['device_code'];
        final userCode = json['user_code'];
        // Google says verification_url; RFC 8628 says verification_uri.
        final verification =
            json['verification_url'] ?? json['verification_uri'];
        final expiresIn = json['expires_in'];
        if (deviceCode is! String ||
            userCode is! String ||
            verification is! String ||
            expiresIn is! num) {
          throw const FormatException('malformed device code response');
        }
        final expiresAt = _now().add(Duration(seconds: expiresIn.toInt()));
        var interval =
            Duration(seconds: (json['interval'] as num?)?.toInt() ?? 5);
        controller.add(DeviceCodePending(
          userCode: userCode,
          verificationUrl: Uri.parse(verification),
          expiresAt: expiresAt,
        ));

        while (!cancelled) {
          await Future.any<void>([_delay(interval), done.future]);
          if (cancelled) return;
          if (!_now().isBefore(expiresAt)) {
            controller.add(const DeviceCodeExpired());
            return;
          }
          final GoogleOAuthResponse res;
          try {
            res = await auth.postForm(googleTokenEndpoint, {
              'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
              'device_code': deviceCode,
              'client_id': auth.clientId,
              'client_secret': auth.clientSecret,
            });
          } on BackupRelayException catch (e) {
            // A dropped poll is not a failed sign-in; try again next interval.
            if (e.kind == BackupRelayError.network) continue;
            rethrow;
          }
          if (cancelled) return;
          if (res.status == 200) {
            final email = await auth.completeSignIn(
              res.json,
              isCancelled: () => cancelled,
            );
            if (!cancelled) controller.add(DeviceCodeDone(email));
            return;
          }
          switch (res.error) {
            case 'authorization_pending':
              continue;
            case 'slow_down':
              interval += _slowDownStep;
            case 'access_denied':
              controller.add(const DeviceCodeDenied());
              return;
            case 'expired_token':
              controller.add(const DeviceCodeExpired());
              return;
            default:
              throw auth.oauthError(res);
          }
        }
      } catch (e, st) {
        if (!cancelled) controller.addError(e, st);
      } finally {
        if (!controller.isClosed) await controller.close();
      }
    }

    controller = StreamController<DeviceCodeState>(
      onListen: () => unawaited(run()),
      onCancel: () {
        cancelled = true;
        if (!done.isCompleted) done.complete();
      },
    );
    return controller.stream;
  }
}
