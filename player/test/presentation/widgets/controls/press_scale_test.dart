import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/controls/press_scale.dart';

double _scale(WidgetTester tester) {
  final t = tester.widget<Transform>(find.byKey(PressScale.scaleKey));
  return t.transform.storage[0];
}

Widget _host(Widget child, {bool disableAnimations = false}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Center(child: child),
    ),
  );
}

class _Probe extends StatelessWidget {
  const _Probe({this.onActivate, this.autofocus = false});
  final VoidCallback? onActivate;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: autofocus,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onActivate?.call();
            return null;
          },
        ),
      },
      child: const SizedBox(
        key: ValueKey('probe'),
        width: 80,
        height: 40,
        child: ColoredBox(color: Color(0xFF000000)),
      ),
    );
  }
}

void main() {
  testWidgets('scales to 0.97 while a pointer is down', (tester) async {
    await tester.pumpWidget(_host(const PressScale(child: _Probe())));
    expect(_scale(tester), 1.0);
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('probe'))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_scale(tester), closeTo(PressScale.pressedScale, 1e-6));
    await g.up();
    await tester.pumpAndSettle();
    expect(_scale(tester), 1.0);
  });

  testWidgets('scales while Select is held, activation fires once', (
    tester,
  ) async {
    var activations = 0;
    await tester.pumpWidget(
      _host(
        PressScale(
          child: _Probe(autofocus: true, onActivate: () => activations++),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_scale(tester), closeTo(PressScale.pressedScale, 1e-6));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(_scale(tester), 1.0);
    expect(activations, 1);
  });

  testWidgets('no animation under reduced motion', (tester) async {
    await tester.pumpWidget(
      _host(const PressScale(child: _Probe()), disableAnimations: true),
    );
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('probe'))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_scale(tester), 1.0);
    await g.up();
  });

  testWidgets('enabled: false never scales', (tester) async {
    await tester.pumpWidget(
      _host(const PressScale(enabled: false, child: _Probe())),
    );
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('probe'))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_scale(tester), 1.0);
    await g.up();
  });

  testWidgets('adds no focus stop', (tester) async {
    Future<List<Key?>> order(bool wrap) async {
      await tester.pumpWidget(
        _host(
          FocusTraversalGroup(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Focus(key: ValueKey('a'), child: SizedBox(width: 20)),
                wrap
                    ? const PressScale(
                        child: Focus(
                          key: ValueKey('b'),
                          child: SizedBox(width: 20),
                        ),
                      )
                    : const Focus(
                        key: ValueKey('b'),
                        child: SizedBox(width: 20),
                      ),
              ],
            ),
          ),
        ),
      );
      final ctx = tester.element(find.byKey(const ValueKey('a')));
      final nodes = FocusScope.of(ctx).traversalDescendants
          .where((n) => n.canRequestFocus)
          .toList();
      // Traversal order is the order the policy visits nodes from the scope.
      final visited = <FocusNode>[];
      final scopeNode = FocusScope.of(ctx);
      scopeNode.requestFocus(nodes.first);
      await tester.pump();
      visited.add(FocusManager.instance.primaryFocus!);
      while (FocusManager.instance.primaryFocus!.nextFocus()) {
        await tester.pump();
        final f = FocusManager.instance.primaryFocus!;
        if (visited.contains(f)) break;
        visited.add(f);
      }
      return visited.map((n) => n.context?.widget.key).toList();
    }

    final plain = await order(false);
    final wrapped = await order(true);
    expect(wrapped.length, plain.length);
    expect(wrapped, plain);
  });
}
