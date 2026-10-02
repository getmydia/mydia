// Network artwork loads through `ArtworkImage`
// (lib/presentation/widgets/artwork_image.dart) or `artworkImageProvider`.
// A `CachedNetworkImage` built directly makes its own provider, without the
// replay-safe codec, and its artwork turns black on Firefox and vanishes on
// Safari once it scrolls back into view. This keeps one from creeping back in
// by copy-paste.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// A constructor call or a `.new` tear-off. Type references alone are fine.
final RegExp _rawImage =
    RegExp(r'\bCachedNetworkImage(Provider)?\s*(\(|\.new\b)');

// The one file allowed to name the provider: it defines the subclass.
const String _allowed = 'lib/core/cache/artwork_decode.dart';

bool _isSource(File file) =>
    file.path.endsWith('.dart') &&
    !file.path.endsWith('.g.dart') &&
    !file.path.endsWith('.graphql.dart') &&
    !file.path.endsWith('.freezed.dart');

void main() {
  test('the scan matches construction and nothing else', () {
    expect(_rawImage.hasMatch('child: CachedNetworkImage('), isTrue);
    expect(_rawImage.hasMatch('CachedNetworkImageProvider(url)'), isTrue);
    expect(_rawImage.hasMatch('urls.map(CachedNetworkImage.new)'), isTrue);
    expect(_rawImage.hasMatch('CachedNetworkImageProvider.new'), isTrue);
    expect(_rawImage.hasMatch('CachedNetworkImageProvider key,'), isFalse);
    expect(_rawImage.hasMatch('extends CachedNetworkImageProvider {'), isFalse);
    expect(_rawImage.hasMatch('CachedNetworkImage.newest'), isFalse);
  });

  test('lib/ builds no CachedNetworkImage directly', () {
    final offenders = <String>[];
    final files = Directory('lib').listSync(recursive: true).whereType<File>();
    for (final file in files.where(_isSource)) {
      if (file.path.replaceAll(r'\', '/') == _allowed) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        // Comments may still name the old widget when explaining history.
        if (line.startsWith('//')) continue;
        if (_rawImage.hasMatch(line)) {
          offenders.add('${file.path}:${i + 1}: $line');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Use ArtworkImage(...) or artworkImageProvider(...):\n'
          '${offenders.join('\n')}',
    );
  });
}
