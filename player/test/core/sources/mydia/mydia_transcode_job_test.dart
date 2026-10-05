import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_job_service.dart';
import 'package:player/core/sources/mydia/mydia_transcode_job.dart';
import 'package:player/domain/models/download_option.dart';
import 'package:player/domain/models/download_plan.dart';

import '../../downloads/download_test_harness.dart';

void main() {
  MydiaTranscodeJob job(FakeDownloadJobService jobs) => MydiaTranscodeJob(
        jobs: jobs,
        contentType: 'movie',
        id: '42',
        resolution: '720p',
        fileFor: (jobId) async =>
            DirectFile(url: 'https://test.invalid/$jobId', extension: 'mp4'),
      );

  test('prepare maps the server status', () async {
    final jobs = FakeDownloadJobService(
        status: const DownloadJobStatus(
            jobId: 'j9',
            status: DownloadJobStatusType.transcoding,
            progress: 0.25,
            currentFileSize: 5));
    final snap = await job(jobs).prepare();
    expect(snap.jobId, 'j9');
    expect(snap.ready, isFalse);
    expect(snap.progress, 0.25);
    expect(snap.fileSize, 5);
    expect(jobs.prepareCount, 1);
  });

  test('a 404 on status is a dead job', () async {
    final jobs = FakeDownloadJobService()
      ..statusError = DownloadServiceException('gone', statusCode: 404);
    expect(() => job(jobs).status('j1'), throwsA(isA<DeadJobException>()));
  });

  test('cancel reaches the server', () async {
    final jobs = FakeDownloadJobService();
    await job(jobs).cancel('j1');
    expect(jobs.cancelCount, 1);
  });
}
