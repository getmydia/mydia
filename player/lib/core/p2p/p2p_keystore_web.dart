import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'p2p_keystore.dart';

const _dbName = 'mydia';
const _dbVersion = 1;
const _storeName = 'mydia_p2p';
const _keyName = 'node_secret';

/// IndexedDB-backed secret key storage.
///
/// The key is the browser's identity to every instance it has paired with, so
/// clearing site data unpairs the browser. That is the intended behavior: it
/// is the user-facing "forget this browser" action.
class _WebKeystore implements P2pKeystore {
  @override
  Future<Uint8List?> read() async {
    final db = await _openDb();
    try {
      final store =
          db.transaction(_storeName.toJS, 'readonly').objectStore(_storeName);
      final value = await _await(store.get(_keyName.toJS));
      if (value.isUndefinedOrNull) return null;
      return (value as JSUint8Array).toDart;
    } finally {
      db.close();
    }
  }

  @override
  Future<void> write(Uint8List secret) async {
    final db = await _openDb();
    try {
      final transaction = db.transaction(_storeName.toJS, 'readwrite');

      // Attach the commit handlers before issuing the put, never after
      // awaiting it. Attaching them afterwards would work only as long as the
      // microtask resuming this function drains before the browser dispatches
      // `complete`, and the price of that assumption ever failing is a
      // write() that never returns.
      final committed = _awaitTransaction(transaction);

      // A successful put request is not yet a durable write: the transaction
      // can still abort at commit, and reporting success there would cost the
      // identity on the next load.
      final stored = _await(
        transaction.objectStore(_storeName).put(secret.toJS, _keyName.toJS),
      );

      // Both, not just the commit: a failed put aborts the transaction, so
      // `committed` reports it too, but leaving `stored` unawaited would raise
      // that same failure a second time as an unhandled async error.
      // Future.wait lets the transaction settle before the close() below.
      await Future.wait<void>([stored.then((_) {}), committed]);
    } finally {
      db.close();
    }
  }

  /// Open the database, creating the object store on the first ever load.
  ///
  /// Each call opens its own connection and the caller closes it, so a version
  /// bump later cannot be blocked by a connection this file left open.
  Future<web.IDBDatabase> _openDb() {
    final completer = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_dbName, _dbVersion);

    request.onupgradeneeded = (web.Event _) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }.toJS;

    request.onsuccess = (web.Event _) {
      if (!completer.isCompleted) {
        completer.complete(request.result as web.IDBDatabase);
      }
    }.toJS;

    request.onerror = (web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Failed to open IndexedDB "$_dbName": '
              '${_describe(request.error)}'),
        );
      }
    }.toJS;

    // Unreachable while _dbVersion stays at 1, because an upgrade can only run
    // on a database no other connection has yet opened. It stops being
    // unreachable the moment someone bumps the version, and the failure without
    // this handler is an open that never settles. Failing loudly points at the
    // cause; whoever bumps the version should replace this with closing the
    // other connection, since `success` still follows once the block clears.
    request.onblocked = (web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError(
            'Opening IndexedDB "$_dbName" at version $_dbVersion is blocked by '
            'another connection holding an older version open.',
          ),
        );
      }
    }.toJS;

    return completer.future;
  }

  /// Bridge an IndexedDB request onto a Future.
  Future<JSAny?> _await(web.IDBRequest request) {
    final completer = Completer<JSAny?>();

    request.onsuccess = (web.Event _) {
      if (!completer.isCompleted) completer.complete(request.result);
    }.toJS;

    request.onerror = (web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('IndexedDB request failed: ${_describe(request.error)}'),
        );
      }
    }.toJS;

    return completer.future;
  }

  /// Bridge a transaction's commit onto a Future.
  Future<void> _awaitTransaction(web.IDBTransaction transaction) {
    final completer = Completer<void>();

    transaction.oncomplete = (web.Event _) {
      if (!completer.isCompleted) completer.complete();
    }.toJS;

    void fail(web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('IndexedDB transaction did not commit: '
              '${_describe(transaction.error)}'),
        );
      }
    }

    transaction.onerror = fail.toJS;
    transaction.onabort = fail.toJS;

    return completer.future;
  }

  String _describe(web.DOMException? error) =>
      error == null ? 'unknown error' : '${error.name}: ${error.message}';
}

P2pKeystore createKeystore() => _WebKeystore();
