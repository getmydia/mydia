import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/download_option.dart';
import 'package:player/presentation/widgets/quality_download_dialog.dart';

Future<void> _open(
  WidgetTester tester,
  Future<List<DownloadOption>> options, {
  void Function(DownloadOption?)? onPicked,
  // A dialog still loading animates forever, so it cannot settle.
  bool settle = true,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          final picked = await pickDownloadOption(context,
              title: 'Quill Harbor', options: options);
          onPicked?.call(picked);
        },
        child: const Text('go'),
      ),
    ),
  ));
  await tester.tap(find.text('go'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  const original = DownloadOption(
      resolution: 'original',
      label: 'Original',
      estimatedSize: 41019000000,
      container: 'mkv');

  testWidgets('a lone original asks for confirmation with size and container',
      (tester) async {
    await _open(tester, Future.value([original]));
    expect(find.byKey(const Key('download-confirm-original')), findsOneWidget);
    expect(find.textContaining('38.20 GB'), findsOneWidget);
    expect(find.textContaining('MKV'), findsOneWidget);
  });

  testWidgets('confirming a lone original returns it', (tester) async {
    DownloadOption? picked;
    await _open(tester, Future.value([original]), onPicked: (o) => picked = o);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(picked, same(original));
  });

  testWidgets('cancelling returns null', (tester) async {
    DownloadOption? picked = original;
    await _open(tester, Future.value([original]), onPicked: (o) => picked = o);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(picked, isNull);
  });

  testWidgets('several options show the picker', (tester) async {
    await _open(
        tester,
        Future.value([
          original,
          const DownloadOption(
              resolution: '720p', label: '720p', estimatedSize: 1000),
        ]));
    expect(find.byKey(const Key('download-option-720p')), findsOneWidget);
    expect(find.byKey(const Key('download-confirm-original')), findsNothing);
  });

  testWidgets('a failed lookup shows the error', (tester) async {
    final lookup = Completer<List<DownloadOption>>();
    await _open(tester, lookup.future, settle: false);
    expect(find.text('Loading quality options...'), findsOneWidget);
    lookup.completeError('no route');
    await tester.pumpAndSettle();
    expect(find.text('Failed to load options'), findsOneWidget);
  });
}
