/// This is copied from Cargokit (which is the official way to use it currently)
/// Details: https://fzyzcjy.github.io/flutter_rust_bridge/manual/integrate/builtin

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'android_environment.dart';
import 'cargo.dart';
import 'environment.dart';
import 'options.dart';
import 'rust_toolchain_file.dart';
import 'rustup.dart';
import 'target.dart';
import 'util.dart';

final _log = Logger('builder');

enum BuildConfiguration {
  debug,
  release,
  profile,
}

extension on BuildConfiguration {
  bool get isDebug => this == BuildConfiguration.debug;
  String get rustName => switch (this) {
        BuildConfiguration.debug => 'debug',
        BuildConfiguration.release => 'release',
        BuildConfiguration.profile => 'release',
      };
}

class BuildException implements Exception {
  final String message;

  BuildException(this.message);

  @override
  String toString() {
    return 'BuildException: $message';
  }
}

class BuildEnvironment {
  final BuildConfiguration configuration;
  final CargokitCrateOptions crateOptions;
  final String targetTempDir;
  final String manifestDir;
  final CrateInfo crateInfo;

  final bool isAndroid;
  final String? androidSdkPath;
  final String? androidNdkVersion;
  final int? androidMinSdkVersion;
  final String? javaHome;

  BuildEnvironment({
    required this.configuration,
    required this.crateOptions,
    required this.targetTempDir,
    required this.manifestDir,
    required this.crateInfo,
    required this.isAndroid,
    this.androidSdkPath,
    this.androidNdkVersion,
    this.androidMinSdkVersion,
    this.javaHome,
  });

  static BuildConfiguration parseBuildConfiguration(String value) {
    // XCode configuration adds the flavor to configuration name.
    final firstSegment = value.split('-').first;
    final buildConfiguration = BuildConfiguration.values.firstWhereOrNull(
      (e) => e.name == firstSegment,
    );
    if (buildConfiguration == null) {
      _log.warning('Unknown build configuraiton $value, will assume release');
      return BuildConfiguration.release;
    }
    return buildConfiguration;
  }

  static BuildEnvironment fromEnvironment({
    required bool isAndroid,
  }) {
    final buildConfiguration =
        parseBuildConfiguration(Environment.configuration);
    final manifestDir = Environment.manifestDir;
    final crateOptions = CargokitCrateOptions.load(
      manifestDir: manifestDir,
    );
    final crateInfo = CrateInfo.load(manifestDir);
    return BuildEnvironment(
      configuration: buildConfiguration,
      crateOptions: crateOptions,
      targetTempDir: Environment.targetTempDir,
      manifestDir: manifestDir,
      crateInfo: crateInfo,
      isAndroid: isAndroid,
      androidSdkPath: isAndroid ? Environment.sdkPath : null,
      androidNdkVersion: isAndroid ? Environment.ndkVersion : null,
      androidMinSdkVersion:
          isAndroid ? int.parse(Environment.minSdkVersion) : null,
      javaHome: isAndroid ? Environment.javaHome : null,
    );
  }
}

class RustBuilder {
  final Target target;
  final BuildEnvironment environment;

  RustBuilder({
    required this.target,
    required this.environment,
  });

  void prepare(
    Rustup rustup,
  ) {
    final toolchain = _toolchain;
    if (rustup.installedTargets(toolchain) == null) {
      rustup.installToolchain(toolchain);
    }
    if (toolchain == 'nightly') {
      rustup.installRustSrcForNightly();
    }
    if (!rustup.installedTargets(toolchain)!.contains(target.rust)) {
      rustup.installTarget(target.rust, toolchain: toolchain);
    }
  }

  CargoBuildOptions? get _buildOptions =>
      environment.crateOptions.cargo[environment.configuration];

  // LOCAL CHANGE (mydia, #252): upstream hardcodes 'stable' here. That is an
  // explicit rustup toolchain name, so it overrides rust-toolchain.toml,
  // RUSTUP_TOOLCHAIN and any pinned toolchain on PATH, which made the compiler
  // behind every shipped .so a per-machine accident. The repo pin is consulted
  // between upstream's explicit cargokit_options.yaml opt-in and upstream's
  // fallback, so a tree with no rust-toolchain.toml behaves exactly as before.
  late final String? _pinnedToolchain =
      resolveToolchainChannel(environment.manifestDir);

  String get _toolchain =>
      _buildOptions?.toolchain.name ?? _pinnedToolchain ?? 'stable';

  /// LOCAL CHANGE (mydia, #252): the path to `cargo` on PATH, or null.
  ///
  /// Used to decide whether this build goes through rustup at all. See
  /// [buildsThroughRustup].
  static String? cargoOnPath() {
    final envPath = Platform.environment['PATH'];
    if (envPath == null) {
      return null;
    }
    final separator = Platform.isWindows ? ';' : ':';
    final executable = Platform.isWindows ? 'cargo.exe' : 'cargo';
    for (final dir in envPath.split(separator)) {
      if (dir.isEmpty) {
        continue;
      }
      final candidate = path.join(dir, executable);
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  /// LOCAL CHANGE (mydia, #252): whether the build will go through rustup.
  ///
  /// True when there is no `cargo` on PATH, or when the one there is a rustup
  /// proxy (rustup and its proxies share a bin directory). False when PATH
  /// offers a standalone cargo, such as a Nix-provided toolchain, in which case
  /// rustup is not involved and installing toolchains or targets into it would
  /// be a pointless download.
  static bool buildsThroughRustup() {
    final cargo = cargoOnPath();
    if (cargo == null) {
      return true;
    }
    final rustup = Rustup.executablePath();
    if (rustup == null) {
      return false;
    }
    return path.equals(path.dirname(cargo), path.dirname(rustup));
  }

  /// Returns the path of directory containing build artifacts.
  Future<String> build() async {
    // LOCAL CHANGE (mydia, #252): make the resolved toolchain visible, so a
    // fallback to `stable` shows up in build output instead of passing silently.
    final cargo = cargoOnPath();
    _log.info('Building with Rust toolchain "$_toolchain" '
        '(pin from rust-toolchain.toml: ${_pinnedToolchain ?? "none found"}, '
        'cargo: ${cargo ?? "via rustup run"})');
    final extraArgs = _buildOptions?.flags ?? [];
    final manifestPath = path.join(environment.manifestDir, 'Cargo.toml');
    final cargoArgs = [
      'build',
      ...extraArgs,
      '--manifest-path',
      manifestPath,
      '-p',
      environment.crateInfo.packageName,
      if (!environment.configuration.isDebug) '--release',
      '--target',
      target.rust,
      '--target-dir',
      environment.targetTempDir,
    ];
    final buildEnvironment = await _buildEnvironment();
    if (cargo != null) {
      // LOCAL CHANGE (mydia, #252): invoke cargo directly and express the pin
      // through RUSTUP_TOOLCHAIN, which rustup's proxies honour (and which
      // auto-installs a missing toolchain) while a standalone cargo simply
      // ignores it. Upstream's `rustup run <toolchain> cargo` instead forces
      // rustup's own dynamically linked binaries, which fail under the Gradle
      // daemon on NixOS with "libz.so.1: cannot open shared object file".
      runCommand(
        cargo,
        cargoArgs,
        environment: {
          ...buildEnvironment,
          'RUSTUP_TOOLCHAIN': _toolchain,
        },
      );
    } else {
      // No cargo on PATH, which is normal inside Xcode and CocoaPods build
      // phases. Fall back to rustup, resolved by absolute path.
      runCommand(
        'rustup',
        ['run', _toolchain, 'cargo', ...cargoArgs],
        environment: buildEnvironment,
      );
    }
    return path.join(
      environment.targetTempDir,
      target.rust,
      environment.configuration.rustName,
    );
  }

  Future<Map<String, String>> _buildEnvironment() async {
    if (target.android == null) {
      return {};
    } else {
      final sdkPath = environment.androidSdkPath;
      final ndkVersion = environment.androidNdkVersion;
      final minSdkVersion = environment.androidMinSdkVersion;
      if (sdkPath == null) {
        throw BuildException('androidSdkPath is not set');
      }
      if (ndkVersion == null) {
        throw BuildException('androidNdkVersion is not set');
      }
      if (minSdkVersion == null) {
        throw BuildException('androidMinSdkVersion is not set');
      }
      final env = AndroidEnvironment(
        sdkPath: sdkPath,
        ndkVersion: ndkVersion,
        minSdkVersion: minSdkVersion,
        targetTempDir: environment.targetTempDir,
        target: target,
      );
      if (!env.ndkIsInstalled() && environment.javaHome != null) {
        env.installNdk(javaHome: environment.javaHome!);
      }
      return env.buildEnvironment();
    }
  }
}
