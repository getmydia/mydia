/// Shared `flutter_secure_storage` platform options.
///
/// Every `FlutterSecureStorage` instance in the app must use these so the
/// keychain/keystore backend is consistent across services.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Android: use the EncryptedSharedPreferences backend.
const kAndroidSecureStorageOptions = AndroidOptions(
  encryptedSharedPreferences: true,
);

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
