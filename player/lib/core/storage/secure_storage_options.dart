/// Shared `flutter_secure_storage` platform options.
///
/// Every `FlutterSecureStorage` instance in the app must use these so the
/// keychain/keystore backend is consistent across services.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Android: the package's default backend.
///
/// This used to pass `encryptedSharedPreferences: true`, selecting the Jetpack
/// Security backend. `flutter_secure_storage` 11.0.0 removed that backend and
/// the parameter with it: v10 migrated any data it held into the custom cipher
/// storage that is now the only Android implementation, so there is nothing
/// left to opt into and no replacement to pass. The constant stays so both call
/// sites keep a single place to change if Android ever needs an option again.
const kAndroidSecureStorageOptions = AndroidOptions();

/// macOS: use the legacy file-based login keychain, not the data-protection
/// keychain.
///
/// `MacOsOptions.usesDataProtectionKeychain` defaults to `true`, which routes
/// to the iOS-style keychain. That keychain requires the app to carry a
/// keychain access group (via an `application-identifier` or
/// `keychain-access-groups` entitlement). Mydia Player ships as a Developer ID
/// app signed without entitlements, so every read/write there fails with
/// `errSecMissingEntitlement` (-34018) and credentials silently stop
/// persisting across launches.
///
/// The legacy keychain has no entitlement requirement and works for any signed
/// bundle, so it is the correct backend for this distribution model.
const kMacOsSecureStorageOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock,
  usesDataProtectionKeychain: false,
);
