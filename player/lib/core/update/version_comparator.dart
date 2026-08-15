/// Semver comparison utilities for app update detection.
class VersionComparator {
  /// Compares two semver strings. Returns true if [remote] is newer than [current].
  ///
  /// Supports versions like "1.2.3", "1.2.3-beta.1", "v1.2.3".
  /// Pre-release versions (with a hyphen suffix) are considered older than
  /// the same version without a suffix (e.g. 1.2.3-beta < 1.2.3).
  static bool isNewer(String current, String remote) {
    final currentParsed = _parse(current);
    final remoteParsed = _parse(remote);
    if (currentParsed == null || remoteParsed == null) return false;
    return _compare(remoteParsed, currentParsed) > 0;
  }

  /// Compares two versions on their release core only, for compatibility gates.
  ///
  /// Returns negative when [a] is older than [b], zero when they match, and
  /// positive when [a] is newer. Returns null when either side cannot be
  /// parsed, which callers must treat as "unknown" and act on by doing nothing.
  ///
  /// This deliberately differs from [isNewer] in three ways:
  ///
  /// - It strips a `*<sha>` suffix. `System.app_version()` returns
  ///   "0.9.0*abc1234" on master builds, which would otherwise fail to parse.
  /// - It strips a `+<build-metadata>` suffix, which [isNewer] cannot parse at
  ///   all: its parser only splits on a hyphen, so a `+` suffix is left
  ///   attached to the patch segment and fails `int.tryParse`.
  /// - It ignores prerelease suffixes. [isNewer] sorts "0.9.0-rc1" below
  ///   "0.9.0", which is right for picking the newest release but wrong for a
  ///   compatibility floor: an RC of 0.9.0 carries the 0.9.0 contract, and
  ///   sorting it low would show every RC tester a spurious update banner.
  static int? compareCore(String a, String b) {
    final parsedA = _parseCore(a);
    final parsedB = _parseCore(b);
    if (parsedA == null || parsedB == null) return null;

    if (parsedA.major != parsedB.major) {
      return parsedA.major.compareTo(parsedB.major);
    }
    if (parsedA.minor != parsedB.minor) {
      return parsedA.minor.compareTo(parsedB.minor);
    }
    return parsedA.patch.compareTo(parsedB.patch);
  }

  /// Parses a version string, stripping a leading "v" if present.
  static _SemVer? _parse(String version) {
    var v = version.trim();
    if (v.startsWith('v') || v.startsWith('V')) {
      v = v.substring(1);
    }

    // Split off pre-release suffix
    String? preRelease;
    final hyphenIndex = v.indexOf('-');
    if (hyphenIndex != -1) {
      preRelease = v.substring(hyphenIndex + 1);
      v = v.substring(0, hyphenIndex);
    }

    final parts = v.split('.');
    if (parts.length < 2 || parts.length > 3) return null;

    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    final patch = parts.length > 2 ? int.tryParse(parts[2]) : 0;

    if (major == null || minor == null || patch == null) return null;

    return _SemVer(major, minor, patch, preRelease);
  }

  /// Parses a version down to major/minor/patch, discarding everything a
  /// compatibility gate should not weigh: a leading "v", a `*<sha>` build
  /// marker, and any prerelease or build-metadata suffix.
  static _SemVer? _parseCore(String version) {
    var v = version.trim();
    if (v.startsWith('v') || v.startsWith('V')) {
      v = v.substring(1);
    }

    for (final marker in const ['*', '-', '+']) {
      final index = v.indexOf(marker);
      if (index != -1) v = v.substring(0, index);
    }

    final parts = v.split('.');
    if (parts.length < 2 || parts.length > 3) return null;

    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    final patch = parts.length > 2 ? int.tryParse(parts[2]) : 0;

    if (major == null || minor == null || patch == null) return null;

    return _SemVer(major, minor, patch, null);
  }

  /// Returns positive if a > b, negative if a < b, zero if equal.
  static int _compare(_SemVer a, _SemVer b) {
    if (a.major != b.major) return a.major.compareTo(b.major);
    if (a.minor != b.minor) return a.minor.compareTo(b.minor);
    if (a.patch != b.patch) return a.patch.compareTo(b.patch);

    // Both have no pre-release → equal
    if (a.preRelease == null && b.preRelease == null) return 0;
    // Release > pre-release
    if (a.preRelease == null && b.preRelease != null) return 1;
    if (a.preRelease != null && b.preRelease == null) return -1;

    // Both have pre-release — lexicographic compare
    return a.preRelease!.compareTo(b.preRelease!);
  }
}

class _SemVer {
  final int major;
  final int minor;
  final int patch;
  final String? preRelease;

  const _SemVer(this.major, this.minor, this.patch, this.preRelease);
}
