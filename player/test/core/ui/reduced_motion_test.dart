import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/ui/reduced_motion.dart';

/// Pumps [child] under a [MediaQuery] with the given accessibility flags and
/// returns nothing — the child captures the value it reads.
Widget _wrap({
  required Widget child,
  bool disableAnimations = false,
  bool accessibleNavigation = false,
}) {
  return MediaQuery(
    data: MediaQueryData(
      disableAnimations: disableAnimations,
      accessibleNavigation: accessibleNavigation,
    ),
    child: Directionality(textDirection: TextDirection.ltr, child: child),
  );
}

/// Small consumer that records what it read from [ReducedMotion] and how many
/// times it has rebuilt, so tests can assert on reactivity.
class _Probe extends StatelessWidget {
  const _Probe({required this.onBuild});

  final void Function(bool reduceMotion) onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild(ReducedMotion.of(context));
    return const SizedBox.shrink();
  }
}

void main() {
  group('ReducedMotion.of', () {
    testWidgets('returns true when disableAnimations is true (AE4)', (
      tester,
    ) async {
      bool? captured;
      await tester.pumpWidget(
        _wrap(
          disableAnimations: true,
          child: _Probe(onBuild: (v) => captured = v),
        ),
      );
      expect(captured, isTrue);
    });

    testWidgets('returns true when accessibleNavigation is true and '
        'disableAnimations is false', (tester) async {
      bool? captured;
      await tester.pumpWidget(
        _wrap(
          accessibleNavigation: true,
          child: _Probe(onBuild: (v) => captured = v),
        ),
      );
      expect(captured, isTrue);
    });

    testWidgets('returns false under default MediaQueryData', (tester) async {
      bool? captured;
      await tester.pumpWidget(
        _wrap(child: _Probe(onBuild: (v) => captured = v)),
      );
      expect(captured, isFalse);
    });

    testWidgets('rebuilds dependents when MediaQuery flips at runtime', (
      tester,
    ) async {
      final reads = <bool>[];
      Widget build(bool disableAnimations) => _wrap(
        disableAnimations: disableAnimations,
        child: _Probe(onBuild: reads.add),
      );

      await tester.pumpWidget(build(false));
      expect(reads.last, isFalse);

      // Flip the inherited MediaQuery; the consumer must re-read the value.
      await tester.pumpWidget(build(true));
      expect(reads.last, isTrue);
    });
  });

  group('ReducedMotion.duration', () {
    testWidgets('passes the duration through when motion is allowed', (
      tester,
    ) async {
      late Duration captured;
      await tester.pumpWidget(
        _wrap(
          child: Builder(
            builder: (context) {
              captured = ReducedMotion.duration(
                context,
                const Duration(milliseconds: 300),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(captured, const Duration(milliseconds: 300));
    });

    testWidgets('collapses to zero when motion is suppressed', (tester) async {
      late Duration captured;
      await tester.pumpWidget(
        _wrap(
          disableAnimations: true,
          child: Builder(
            builder: (context) {
              captured = ReducedMotion.duration(
                context,
                const Duration(milliseconds: 300),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(captured, Duration.zero);
    });
  });

  group('ReducedMotionContext extension', () {
    testWidgets('reduceMotion mirrors ReducedMotion.of', (tester) async {
      bool? captured;
      await tester.pumpWidget(
        _wrap(
          disableAnimations: true,
          child: Builder(
            builder: (context) {
              captured = context.reduceMotion;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(captured, isTrue);
    });
  });
}
