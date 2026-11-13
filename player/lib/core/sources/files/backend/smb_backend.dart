/// A files backend over an SMB share, through [SmbNative].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../files_account.dart';
import '../smb_addresses.dart' show capSmbAddresses, normalizeSmbHost;
import '../smb_discovery.dart';
import '../smb_native.dart';
import 'file_system_backend.dart';

/// One share. Paths are share-relative and start with `/`; entries are
/// returned as [SmbNative] gives them.
class SmbBackend implements FileSystemBackend {
  SmbBackend({
    required this.native,
    required this.accountId,
    required this.target,
    required this.credentials,
  });

  final SmbNative native;
  final String accountId;
  final SmbTarget target;
  final SmbCredentials credentials;

  @override
  Future<List<FileEntry>> list(String dir) =>
      native.list(target, credentials, dir);

  @override
  Future<FileEntry?> stat(String path) =>
      native.stat(target, credentials, path);

  @override
  Future<PlayableFile> playable(String path) async => PlayableFile(
      url: await native.open(accountId, target, credentials, path));

  @override
  Future<void> probe() => native.probe(target, credentials, '/');
}

/// An [SmbBackend] built on first use from the stored credentials. A missing
/// or unreadable credential is a refused one, and a refused or unreachable
/// call drops the built backend, so the next call reads the credentials again
/// (after the viewer signs in anew) and probes the addresses from the top.
///
/// The build probes [targets] in order and keeps going past every failure:
/// after a move, the share's old IP can belong to another SMB host that
/// refuses the login. When none answers and [serviceName] is known, it
/// browses mDNS for that name for at most [browseTimeout] and tries the
/// addresses found, unless every stored target refused the login (the
/// password is wrong everywhere). A target other than the first one reaching
/// the share moves to the front of [targets], with what the browse found
/// added at the end, so the next build starts there; it is also handed to
/// [onReachedVia] to be saved.
class LazySmbBackend implements FileSystemBackend {
  LazySmbBackend({
    required this.native,
    required this.accountId,
    required List<SmbTarget> targets,
    required this.credentials,
    this.serviceName,
    this.discovery,
    this.onReachedVia,
    this.browseTimeout = const Duration(seconds: 5),
  })  : assert(targets.isNotEmpty, 'an SMB share has at least one address'),
        _targets = [...targets];

  final SmbNative native;
  final String accountId;

  /// The addresses in the order the next build probes them.
  List<SmbTarget> get targets => List.unmodifiable(_targets);
  final List<SmbTarget> _targets;
  final Future<String?> Function() credentials;
  final String? serviceName;
  final SmbDiscovery? discovery;
  final Future<void> Function(SmbTarget reached, List<SmbTarget> discovered)?
      onReachedVia;
  final Duration browseTimeout;
  Future<SmbBackend>? _backend;

  Future<T> _call<T>(Future<T> Function(SmbBackend b) run) async {
    final f = _resolve();
    final b = await f;
    try {
      return await run(b);
    } on BackendUnauthorized {
      _drop(f);
      rethrow;
    } on BackendUnreachable {
      _drop(f);
      rethrow;
    }
  }

  /// Forgets [f] unless a newer build has already replaced it.
  void _drop(Future<SmbBackend> f) {
    if (identical(_backend, f)) _backend = null;
  }

  Future<SmbBackend> _resolve() {
    final current = _backend;
    if (current != null) return current;
    late final Future<SmbBackend> f;
    f = _build().then(
      (b) => b,
      onError: (Object e, StackTrace st) {
        _drop(f);
        Error.throwWithStackTrace(e, st);
      },
    );
    return _backend = f;
  }

  Future<SmbBackend> _build() async {
    final stored = await credentials();
    if (stored == null) throw const BackendUnauthorized('no credentials');
    final SmbCredentials c;
    try {
      c = SmbCredentials.fromJson(stored);
    } on FormatException catch (e) {
      debugPrint('[FilesSource] Unreadable SMB credentials: $e');
      throw const BackendUnauthorized('unreadable credentials');
    }

    final failures = <BackendFailure>[];
    final order = [..._targets];
    final answered = await _firstAnswering(order, c, failures);
    if (answered != null) {
      if (!identical(answered, order.first)) _reached(answered, const []);
      return _backendOn(answered, c);
    }

    final storedFailures = [...failures];
    final name = serviceName;
    final browser = discovery;
    if (name != null &&
        browser != null &&
        !storedFailures.every((f) => f is BackendUnauthorized)) {
      final server = await _browseFor(browser, name);
      if (server != null) {
        final tried = {for (final t in order) _key(t)};
        final found = _targetsOf(server);
        final fresh = [
          for (final t in found)
            if (!tried.contains(_key(t))) t,
        ];
        final reached = await _firstAnswering(fresh, c, failures);
        if (reached != null) {
          _reached(reached, fresh);
          return _backendOn(reached, c);
        }
      }
    }
    throw _chooseFailure(failures);
  }

  SmbBackend _backendOn(SmbTarget t, SmbCredentials c) => SmbBackend(
      native: native, accountId: accountId, target: t, credentials: c);

  /// The first of [candidates] whose root answers, or null; every failure is
  /// appended to [failures].
  Future<SmbTarget?> _firstAnswering(List<SmbTarget> candidates,
      SmbCredentials c, List<BackendFailure> failures) async {
    for (final t in candidates) {
      try {
        await native.probe(t, c, '/');
        return t;
      } on BackendFailure catch (e) {
        failures.add(e);
      }
    }
    return null;
  }

  /// The first server advertised as [name], or null when none shows up
  /// within [browseTimeout] or the browse ends. The browse is always
  /// cancelled.
  Future<DiscoveredSmbServer?> _browseFor(
      SmbDiscovery browser, String name) async {
    final found = Completer<DiscoveredSmbServer?>();
    final sub = browser.browse().listen(
      (servers) {
        for (final s in servers) {
          if (s.name == name) {
            if (!found.isCompleted) found.complete(s);
            return;
          }
        }
      },
      onDone: () {
        if (!found.isCompleted) found.complete(null);
      },
    );
    try {
      return await found.future.timeout(browseTimeout, onTimeout: () => null);
    } finally {
      await sub.cancel();
    }
  }

  /// [server]'s addresses then its hostname, on its port, for this share.
  List<SmbTarget> _targetsOf(DiscoveredSmbServer server) {
    final share = _targets.first.share;
    final hostname = server.hostname;
    final hosts = [
      ...server.addresses,
      if (hostname != null) hostname,
    ];
    final seen = <String>{};
    return [
      for (final host in hosts.map(normalizeSmbHost))
        if (host.isNotEmpty && seen.add(host))
          SmbTarget(host: host, port: server.port, share: share),
    ];
  }

  static String _key(SmbTarget t) =>
      '${normalizeSmbHost(t.host)}|${t.port}|${t.share}';

  /// The first failure that is not a plain unreachable one (a refused login,
  /// a missing share, an SMB1-only server), else the last unreachable one.
  static BackendFailure _chooseFailure(List<BackendFailure> failures) {
    for (final f in failures) {
      if (f is! BackendUnreachable || f.message == kSmb1OnlyReason) return f;
    }
    return failures.last;
  }

  /// Moves [reached] to the front of [targets] and adds the [discovered]
  /// ones not already there, capped by the same [capSmbAddresses] rule as
  /// the stored list, then reports it.
  void _reached(SmbTarget reached, List<SmbTarget> discovered) {
    final key = _key(reached);
    final next = [reached, ..._targets.where((t) => _key(t) != key)];
    for (final d in discovered) {
      if (!next.any((t) => _key(t) == _key(d))) next.add(d);
    }
    _targets
      ..clear()
      ..addAll(capSmbAddresses(next, (t) => t.host));
    _reportReached(reached, discovered);
  }

  void _reportReached(SmbTarget reached, List<SmbTarget> discovered) {
    final report = onReachedVia;
    if (report == null) return;
    unawaited(Future.sync(() => report(reached, discovered)).catchError(
      (Object e) => debugPrint('[FilesSource] Saving the SMB address: $e'),
    ));
  }

  @override
  Future<List<FileEntry>> list(String dir) => _call((b) => b.list(dir));

  @override
  Future<FileEntry?> stat(String path) => _call((b) => b.stat(path));

  @override
  Future<PlayableFile> playable(String path) => _call((b) => b.playable(path));

  @override
  Future<void> probe() => _call((b) => b.probe());
}
