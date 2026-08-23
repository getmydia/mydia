/// Web device profile: nothing to probe, so this reports the fixed set of
/// containers and codecs browsers decode.
library;

import 'device_profile.dart';

Future<DeviceProfile> detectDeviceProfile() async =>
    const DeviceProfile.webDefault();
