/// Web device profile: containers and codecs are the fixed set browsers
/// decode; HDR is probed from the display and the decoder.
library;

import 'dart:js_interop';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:web/web.dart' as web;

import 'device_profile.dart';
import 'hdr_claims.dart';

const _hevcMain10 = 'video/mp4; codecs="hvc1.2.4.L153.B0"';

Future<DeviceProfile> detectDeviceProfile() async {
  final highDynamicRange = _displayIsHdr();
  final pq = highDynamicRange && await _decodesTransfer('pq');
  final hlg = highDynamicRange && await _decodesTransfer('hlg');

  return const DeviceProfile.webDefault().copyWith(
    hdrFormats: webHdrFormats(
      highDynamicRange: highDynamicRange,
      pq: pq,
      hlg: hlg,
    ),
  );
}

bool _displayIsHdr() {
  try {
    return web.window.matchMedia('(dynamic-range: high)').matches;
  } catch (e) {
    debugPrint('[DeviceProfile] dynamic-range query failed: $e');
    return false;
  }
}

/// Whether the browser reports it can decode 4K HEVC with [transferFunction]; any
/// failure means no.
Future<bool> _decodesTransfer(String transferFunction) async {
  try {
    final config = web.MediaDecodingConfiguration(
      type: 'media-source',
      video: web.VideoConfiguration(
        contentType: _hevcMain10,
        width: 3840,
        height: 2160,
        bitrate: 20000000,
        framerate: 24,
        transferFunction: transferFunction,
      ),
    );
    final info = await web.window.navigator.mediaCapabilities
        .decodingInfo(config)
        .toDart;
    return info.supported;
  } catch (e) {
    debugPrint('[DeviceProfile] decodingInfo($transferFunction) failed: $e');
    return false;
  }
}
