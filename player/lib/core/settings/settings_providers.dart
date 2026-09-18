/// The `SettingsService` every layer reads, including `core/`.
///
/// `settingsServiceProvider` under `presentation/screens/settings/`
/// delegates to this one. A provider in `core/` cannot depend on a screen,
/// and two independent providers would hand out two services whose
/// overrides a test would have to keep in step.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'settings_service.dart';

part 'settings_providers.g.dart';

@riverpod
SettingsService coreSettingsService(Ref ref) => SettingsService();
