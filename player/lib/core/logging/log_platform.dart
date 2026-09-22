/// The platform half of player logging: files and gzip on native, nothing on
/// web, where `openLogStore` answers null.
library;

export 'log_platform_stub.dart' if (dart.library.io) 'log_platform_io.dart'
    show openLogStore, gzipBytes;
