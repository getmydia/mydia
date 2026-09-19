/// Web half of `image_subtitle_sidecar.dart`. A browser has no mpv to hand
/// a bitmap subtitle to, so every fetch is unsupported.
library;

import 'image_subtitle_sidecar.dart';

Future<SidecarFetch> fetchImageSidecar({
  required Uri url,
  required Map<String, String> headers,
  required bool Function() cancelled,
}) async =>
    const SidecarUnsupported();

Future<void> discardImageSidecar(String path) async {}
