import 'dart:io' show gzip;

List<int> gzipEncode(List<int> data) => gzip.encode(data);

List<int> gzipDecode(List<int> data) => gzip.decode(data);
