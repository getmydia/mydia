/// The one place Mydia Player decides where its Hive boxes live.
///
/// Call [initAppHive] instead of `Hive.initFlutter()` or graphql_flutter's
/// `initHiveForFlutter()`. Both of those default their base path to
/// `getApplicationDocumentsDirectory()` with no subdirectory, which on every
/// desktop platform is the user's own Documents folder -- so the app used to
/// drop fifteen boxes' worth of loose `.hive` and `.lock` files straight into
/// it. On Windows that folder is normally redirected into OneDrive, which then
/// syncs live database files while Hive is writing them.
///
/// Boxes now live under `getApplicationSupportDirectory()`: a per-app folder
/// in `%APPDATA%` on Windows, under `~/Library/Application Support` on macOS,
/// under `$XDG_DATA_HOME` on Linux, and the app's private support directory on
/// Android and iOS. [initAppHive] moves an existing install's boxes there on
/// first launch; see `hive_box_migration.dart`.
library;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:path_provider/path_provider.dart';

import 'hive_box_migration.dart';

Future<void>? _init;

/// Initializes Hive under the app's private support directory, once.
///
/// Memoized rather than merely idempotent: several independent startup steps
/// need Hive ready before they open their own box -- window geometry (before
/// the first frame), the GraphQL cache, the fetch log, the download database
/// -- and the subtitle sheet opens one lazily from `initState` with no
/// container in reach. They all call this and only the first does any work.
///
/// A failure is not cached. Whatever went wrong (an unavailable platform
/// directory, a plugin not yet registered) may not still be true on the next
/// attempt, and every caller already treats a failure here as "this feature
/// does not persist for the session" rather than as fatal.
Future<void> initAppHive() => _init ??= _initOnce();

Future<void> _initOnce() async {
  try {
    await _initHive();
  } catch (_) {
    _init = null;
    rethrow;
  }
}

Future<void> _initHive() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kIsWeb) {
    // Hive's web backend is IndexedDB, keyed by box name and scoped to the
    // origin. There is no path to choose and no litter to clean up, so this
    // is the whole of the web story.
    Hive.init(null);
  } else {
    final support = await getApplicationSupportDirectory();
    await _migrateFromDocuments(support.path);
    Hive.init(support.path);
  }

  _registerFlutterAdapters();
}

/// Moves any boxes left in the old location, if that location can be found.
///
/// Runs ahead of `Hive.init` so the boxes are in place before anything opens
/// one, and passes `Hive.isBoxOpen` to cover the case that ordering does not:
/// a caller that opened a box at the old path before reaching here. Hive holds
/// a box's lock file open and deletes it itself on close, so moving the files
/// out from under it turns `box.close()` into a `PathNotFoundException`.
///
/// Resolving Documents is allowed to fail, and failing costs only the
/// migration. On Linux `getApplicationDocumentsDirectory()` is
/// `xdg.getUserDirectory('DOCUMENTS')`, and path_provider turns a null answer
/// into a thrown `MissingPlatformDirectoryException` -- so a machine with no
/// `user-dirs.dirs`, or an XDG setup that simply declares no Documents
/// folder, throws here through no fault of the app. Letting that reach
/// [initAppHive] would leave `Hive.init` uncalled and every box unopenable,
/// which trades all of the app's persistence for a directory it only wanted
/// to read old files out of. There is nothing to migrate from a directory
/// that is not there, and nothing to abandon Hive over.
///
/// This is defence, not a fix for anything observed: the Flatpak sandbox
/// resolves Documents fine despite granting no `--filesystem`, which its
/// smoke-test log confirms by initializing Hive with no complaint.
Future<void> _migrateFromDocuments(String supportPath) async {
  final String documentsPath;
  try {
    documentsPath = (await getApplicationDocumentsDirectory()).path;
  } catch (e) {
    debugPrint('[Hive] No documents directory to migrate from: $e');
    return;
  }

  await migrateHiveBoxes(
    from: documentsPath,
    to: supportPath,
    isBoxOpen: Hive.isBoxOpen,
  );
}

/// The `Color` and `TimeOfDay` adapters `Hive.initFlutter()` registers.
///
/// Replicated here because [initAppHive] replaces that call and these two
/// registrations are the rest of what it did. Nothing in the app persists
/// either type today, but they sit at type IDs 200 and 201, far above the
/// app's own adapters, so keeping them costs nothing and dropping them would
/// be a silent behaviour change waiting to bite whoever first puts a `Color`
/// in a box.
void _registerFlutterAdapters() {
  final color = ColorAdapter();
  if (!Hive.isAdapterRegistered(color.typeId)) {
    Hive.registerAdapter(color);
  }

  const timeOfDay = TimeOfDayAdapter();
  if (!Hive.isAdapterRegistered(timeOfDay.typeId)) {
    Hive.registerAdapter(timeOfDay);
  }
}
