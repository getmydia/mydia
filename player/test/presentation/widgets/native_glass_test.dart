import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/native_glass_support.dart';
import 'package:player/presentation/widgets/native_glass.dart';

/// Captures the engine's `create` calls so a test can read the creation
/// params a platform view was built with.
List<MethodCall> _capturePlatformViews(WidgetTester tester) {
  final calls = <MethodCall>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform_views,
      (call) async {
    calls.add(call);
    return null;
  });
  addTearDown(() =>
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null));
  return calls;
}

Map<Object?, Object?> _paramsOf(MethodCall create) {
  final args = create.arguments as Map<Object?, Object?>;
  final bytes = args['params']! as Uint8List;
  return const StandardMessageCodec()
      .decodeMessage(ByteData.sublistView(bytes))! as Map<Object?, Object?>;
}

Widget _glass({BoxBorder? border}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: NativeGlass(
          cornerRadius: 22,
          tint: const Color(0x80112233),
          border: border,
          fallback: (child) => ColoredBox(
            key: const Key('fallback'),
            color: const Color(0xFF000000),
            child: child,
          ),
          child: const SizedBox(key: Key('content'), width: 100, height: 40),
        ),
      ),
    );

void main() {
  tearDown(() => NativeGlassSupport.debugOverride = null);

  testWidgets('unsupported: builds the fallback around the child',
      (tester) async {
    NativeGlassSupport.debugOverride = false;
    await tester.pumpWidget(_glass());

    expect(find.byKey(const Key('fallback')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('fallback')),
        matching: find.byKey(const Key('content')),
      ),
      findsOneWidget,
    );
    expect(find.byType(UiKitView), findsNothing);
    expect(find.byType(AppKitView), findsNothing);
  });

  testWidgets('never initialized: flutter test sees the fallback',
      (tester) async {
    await tester.pumpWidget(_glass());
    expect(find.byKey(const Key('fallback')), findsOneWidget);
  });

  testWidgets('supported on iOS: native glass under the child, no fallback',
      (tester) async {
    NativeGlassSupport.debugOverride = true;
    final calls = _capturePlatformViews(tester);
    await tester.pumpWidget(_glass());
    await tester.pump();

    expect(find.byKey(const Key('fallback')), findsNothing);
    expect(find.byType(UiKitView), findsOneWidget);
    expect(find.byKey(const Key('content')), findsOneWidget);

    final create = calls.singleWhere((c) => c.method == 'create');
    final args = create.arguments as Map<Object?, Object?>;
    expect(args['viewType'], NativeGlass.viewType);
    expect(_paramsOf(create), {
      'cornerRadius': 22.0,
      'tint': 0x80112233,
      'style': 'regular',
    });

    // The glass is painted first, so the content sits above it.
    final stack = tester.widget<Stack>(find.ancestor(
      of: find.byType(UiKitView),
      matching: find.byType(Stack),
    ));
    expect(stack.children.last, isA<SizedBox>());

    // The native view never takes input.
    expect(
      find.ancestor(
        of: find.byType(UiKitView),
        matching:
            find.byWidgetPredicate((w) => w is IgnorePointer && w.ignoring),
      ),
      findsOneWidget,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('supported on macOS: AppKitView with the same params',
      (tester) async {
    NativeGlassSupport.debugOverride = true;
    final calls = _capturePlatformViews(tester);
    await tester.pumpWidget(_glass());
    await tester.pump();

    expect(find.byType(AppKitView), findsOneWidget);
    final create = calls.singleWhere((c) => c.method == 'create');
    expect(_paramsOf(create)['cornerRadius'], 22.0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('supported elsewhere (Android): still the fallback',
      (tester) async {
    NativeGlassSupport.debugOverride = true;
    await tester.pumpWidget(_glass());
    expect(find.byKey(const Key('fallback')), findsOneWidget);
    expect(NativeGlass.available, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('border is drawn over native glass only', (tester) async {
    NativeGlassSupport.debugOverride = true;
    _capturePlatformViews(tester);
    const rim = Border(right: BorderSide(color: Color(0x33FFFFFF)));
    await tester.pumpWidget(_glass(border: rim));
    await tester.pump();

    final boxes = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
    expect(
      boxes.any((d) =>
          d.decoration is BoxDecoration &&
          (d.decoration as BoxDecoration).border == rim),
      isTrue,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  test('initialize answers false off Apple platforms without the channel',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await NativeGlassSupport.initialize();
      expect(NativeGlassSupport.supported, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
