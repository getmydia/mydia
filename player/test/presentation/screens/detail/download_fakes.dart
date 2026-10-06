import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/domain/models/download_option.dart';
import 'package:player/domain/models/download_plan.dart';
import 'package:player/domain/sources/item.dart';

import '../sources/fake_media_source.dart';

/// A source whose items can be downloaded. [options] decides what the dialog
/// sees, so a test can leave it loading by passing a future that never ends.
class DownloadableFakeSource extends FakeMediaSource implements Downloadable {
  DownloadableFakeSource({Future<List<DownloadOption>>? options})
      : _options = options ??
            Future.value(const [
              DownloadOption(
                  resolution: 'original', label: 'Original', estimatedSize: 1),
            ]);

  final Future<List<DownloadOption>> _options;

  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.downloadable};

  @override
  Future<List<DownloadOption>> downloadOptions(ItemRef ref) => _options;

  @override
  Future<DownloadPlan> resolve(ItemRef ref, String optionId) async =>
      const DirectFile(url: 'https://x.invalid', extension: 'mkv');
}

/// A download manager that has downloaded nothing.
class EmptyDownloadService extends Fake implements DownloadService {
  @override
  bool isDownloaded(ItemRef ref) => false;
}
