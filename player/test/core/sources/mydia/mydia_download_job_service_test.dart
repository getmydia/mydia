import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_job_service.dart';
import 'package:player/core/sources/mydia/mydia_download_job_service.dart';

void main() {
  test('sends the download mutations and parses the answers', () async {
    final sent = <Map<String, dynamic>>[];
    final service = MydiaDownloadJobService(
      request: (document, variables) async {
        sent.add(variables);
        if (variables.containsKey('resolution')) {
          return {
            'prepareDownload': {
              'jobId': 'j1',
              'status': 'ready',
              'progress': 1.0,
              'fileSize': 9,
            }
          };
        }
        return {
          'downloadOptions': [
            {'resolution': 'original', 'label': 'Original', 'estimatedSize': 9}
          ]
        };
      },
    );

    final options = await service.getOptions('movie', '42');
    expect(options.options.single.resolution, 'original');
    expect(sent.first, {'contentType': 'movie', 'id': '42'});

    final job = await service.prepareDownload(
        contentType: 'movie', id: '42', resolution: 'original');
    expect(job.jobId, 'j1');
    expect(job.currentFileSize, 9);
  });

  test('a missing job is a 404', () async {
    final service = MydiaDownloadJobService(
        request: (_, __) async => {'downloadJobStatus': null});
    expect(
      () => service.getJobStatus('gone'),
      throwsA(isA<DownloadServiceException>()
          .having((e) => e.statusCode, 'statusCode', 404)),
    );
  });

  test('a cancel the server refuses throws', () async {
    final service = MydiaDownloadJobService(
        request: (_, __) async => {
              'cancelDownloadJob': {'success': false}
            });
    expect(() => service.cancelJob('j1'),
        throwsA(isA<DownloadServiceException>()));
  });
}
