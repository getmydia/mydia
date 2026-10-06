/// Result of a bulk download operation.
class BulkDownloadResult {
  final int queued;
  final int skipped;
  final int failed;

  const BulkDownloadResult({
    required this.queued,
    required this.skipped,
    required this.failed,
  });

  int get total => queued + skipped + failed;
}
