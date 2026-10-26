/// Why a download failed or stopped, as data the downloads screen words in
/// the viewer's language.
///
/// `DownloadTask.error` is persisted as a String (Hive field 11), so a failure
/// is stored in the encoded form [DownloadFailure.encode] and read back with
/// [DownloadFailure.decode]. Rows written before this existed hold a plain
/// English sentence; they decode as [DownloadFailureCode.unknown] with that
/// text as the detail, and are shown exactly as they were written.
library;

import '../sources/source_error.dart';

enum DownloadFailureCode {
  /// The viewer cancelled it.
  cancelled,

  /// Recovery gave up; [DownloadFailure.count] attempts were made.
  stalled,

  /// The downloads service had not finished starting.
  startingUp,

  /// The source failed; [DownloadFailure.sourceException] rebuilds the
  /// failure.
  source,

  /// The server's transcode failed; the detail is the server's own words.
  transcodeFailed,

  /// The network dropped after [DownloadFailure.count] retries; detail is
  /// the transport's text.
  networkRetries,

  /// The network dropped; detail is the transport's text.
  network,

  /// The network dropped; detail names the error type.
  networkKind,

  /// The server dropped the transcode job.
  jobGone,

  /// The sign-in the download used was refused.
  signInExpired,

  /// The item is gone from the server.
  itemGone,

  /// Nothing more is known; detail is whatever text there was, shown as is.
  unknown,
}

class DownloadFailure {
  const DownloadFailure(
    this.code, {
    this.count,
    this.detail,
    this.sourceKind,
    this.fault,
  });

  /// A failure from a source, keeping its kind, the fault the app recognised
  /// and the server's own words.
  factory DownloadFailure.fromSource(SourceException e) => DownloadFailure(
        DownloadFailureCode.source,
        sourceKind: e.kind,
        fault: e.fault,
        detail: e.fault == null ? e.message : e.detail,
      );

  /// Text with no known cause: shown verbatim.
  const DownloadFailure.text(String this.detail)
      : code = DownloadFailureCode.unknown,
        count = null,
        sourceKind = null,
        fault = null;

  final DownloadFailureCode code;

  /// A number the sentence names: attempts made, or retries spent.
  final int? count;
  final String? detail;
  final SourceErrorKind? sourceKind;
  final SourceFault? fault;

  static const _prefix = 'dlf:';

  /// The persisted form: `dlf:<code>|<count>|<kind>|<fault>|<detail>`. Names
  /// rather than indexes, so reordering an enum cannot change a stored row.
  String encode() => '$_prefix${code.name}|${count ?? ''}|'
      '${sourceKind?.name ?? ''}|${fault?.name ?? ''}|${detail ?? ''}';

  /// Reads a persisted error. Anything not written by [encode], such as a
  /// row from before failures were typed, is [DownloadFailure.text].
  static DownloadFailure decode(String stored) {
    if (!stored.startsWith(_prefix)) return DownloadFailure.text(stored);
    final parts = stored.substring(_prefix.length).split('|');
    if (parts.length < 5) return DownloadFailure.text(stored);
    final code = DownloadFailureCode.values.asNameMap()[parts[0]];
    if (code == null) return DownloadFailure.text(stored);
    // The detail is last and may itself contain the separator.
    final detail = parts.sublist(4).join('|');
    return DownloadFailure(
      code,
      count: int.tryParse(parts[1]),
      sourceKind: SourceErrorKind.values.asNameMap()[parts[2]],
      fault: SourceFault.values.asNameMap()[parts[3]],
      detail: detail.isEmpty ? null : detail,
    );
  }

  /// The source failure this records, for [DownloadFailureCode.source].
  SourceException sourceException() {
    final fault = this.fault;
    if (fault != null) {
      return sourceKind == SourceErrorKind.unsupported
          ? SourceException.unsupportedFault(fault)
          : SourceException.fault(fault, detail: detail);
    }
    return SourceException(sourceKind ?? SourceErrorKind.server, detail);
  }

  @override
  String toString() => encode();
}
