import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/toast/toast_controller.dart';
import 'package:player/presentation/widgets/toast/toast_models.dart';

void main() {
  group('default durations', () {
    test('info and success stay 3s', () {
      expect(ToastMetrics.defaultDuration(ToastKind.info, hasAction: false),
          const Duration(seconds: 3));
      expect(ToastMetrics.defaultDuration(ToastKind.success, hasAction: false),
          const Duration(seconds: 3));
    });

    test('errors stay 5s', () {
      expect(ToastMetrics.defaultDuration(ToastKind.error, hasAction: false),
          const Duration(seconds: 5));
    });

    test('an action extends any non-progress kind to 8s', () {
      expect(ToastMetrics.defaultDuration(ToastKind.info, hasAction: true),
          const Duration(seconds: 8));
      expect(ToastMetrics.defaultDuration(ToastKind.error, hasAction: true),
          const Duration(seconds: 8));
    });

    test('progress waits for its caller, up to 30s', () {
      expect(ToastMetrics.defaultDuration(ToastKind.progress, hasAction: false),
          const Duration(seconds: 30));
      expect(ToastMetrics.defaultDuration(ToastKind.progress, hasAction: true),
          const Duration(seconds: 30));
    });
  });

  group('lifecycle', () {
    test('a toast closes itself after its duration', () {
      fakeAsync((async) {
        final controller = ToastController();
        controller.show('Saved');
        async.elapse(const Duration(milliseconds: 2999));
        expect(controller.current?.message, 'Saved');
        async.elapse(const Duration(milliseconds: 1));
        expect(controller.current, isNull);
        controller.dispose();
      });
    });

    test('an explicit duration wins over the default', () {
      fakeAsync((async) {
        final controller = ToastController();
        controller.show('Denied',
            kind: ToastKind.error, duration: const Duration(seconds: 8));
        async.elapse(const Duration(seconds: 7));
        expect(controller.current, isNotNull);
        async.elapse(const Duration(seconds: 1));
        expect(controller.current, isNull);
        controller.dispose();
      });
    });

    test('showing a second toast replaces the first', () {
      final controller = ToastController();
      controller.show('A');
      controller.show('B');
      expect(controller.current?.message, 'B');
      controller.dispose();
    });

    test("closing a replaced toast's id leaves the current one alone", () {
      final controller = ToastController();
      final a = controller.show('A');
      controller.show('B');
      controller.close(a.id);
      expect(controller.current?.message, 'B');
      controller.dispose();
    });

    test('a replacement runs on its own clock', () {
      fakeAsync((async) {
        final controller = ToastController();
        controller.show('A');
        async.elapse(const Duration(seconds: 2));
        controller.show('B');
        async.elapse(const Duration(seconds: 2));
        expect(controller.current?.message, 'B',
            reason: "A's timer must not close B");
        async.elapse(const Duration(seconds: 1));
        expect(controller.current, isNull);
        controller.dispose();
      });
    });

    test('an icon is kept for info only', () {
      final controller = ToastController();
      expect(controller.show('a', icon: Icons.sync_rounded).icon,
          Icons.sync_rounded);
      expect(
          controller
              .show('b', kind: ToastKind.error, icon: Icons.sync_rounded)
              .icon,
          isNull);
      controller.dispose();
    });

    test('pause holds the toast and resume restarts the full duration', () {
      fakeAsync((async) {
        final controller = ToastController();
        final entry = controller.show('Saved');
        async.elapse(const Duration(seconds: 2));
        controller.pause(entry.id);
        async.elapse(const Duration(seconds: 10));
        expect(controller.current, isNotNull);
        controller.resume(entry.id);
        async.elapse(const Duration(milliseconds: 2999));
        expect(controller.current, isNotNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(controller.current, isNull);
        controller.dispose();
      });
    });

    test('with accessible navigation an action toast waits to be dismissed',
        () {
      fakeAsync((async) {
        final controller = ToastController()..accessibleNavigation = true;
        controller.show('Denied',
            action: ToastAction(label: 'Settings', onPressed: () {}));
        async.elapse(const Duration(minutes: 1));
        expect(controller.current?.message, 'Denied');

        controller.show('Plain');
        async.elapse(const Duration(seconds: 3));
        expect(controller.current, isNull,
            reason: 'only toasts with an action wait');
        controller.dispose();
      });
    });

    test('dispose cancels the pending timer', () {
      fakeAsync((async) {
        final controller = ToastController();
        controller.show('Saved');
        controller.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('notifies on show and close', () {
      final controller = ToastController();
      var notified = 0;
      controller.addListener(() => notified++);
      final entry = controller.show('Saved');
      controller.close(entry.id);
      expect(notified, 2);
      controller.dispose();
    });
  });

  group('claims', () {
    const layer = Size(1400, 900);

    test('no claims, no insets', () {
      final controller = ToastController();
      expect(controller.insetsFor(layer), EdgeInsets.zero);
      controller.dispose();
    });

    test('a left claim insets by its right edge', () {
      final controller = ToastController();
      controller.setClaim(#sidebar,
          const ToastClaim(ToastEdge.left, Rect.fromLTWH(0, 0, 260, 900)));
      expect(controller.insetsFor(layer).left, 260);
      controller.dispose();
    });

    test('a bottom claim insets by its distance from the bottom', () {
      final controller = ToastController();
      controller.setClaim(#dock,
          const ToastClaim(ToastEdge.bottom, Rect.fromLTWH(12, 805, 776, 83)));
      expect(controller.insetsFor(layer).bottom, 95);
      controller.dispose();
    });

    test('each edge takes its largest claim', () {
      final controller = ToastController();
      controller
        ..setClaim(#dock,
            const ToastClaim(ToastEdge.bottom, Rect.fromLTWH(12, 805, 776, 83)))
        ..setClaim(#castBar,
            const ToastClaim(ToastEdge.bottom, Rect.fromLTWH(0, 830, 1400, 70)))
        ..setClaim(#narrow,
            const ToastClaim(ToastEdge.left, Rect.fromLTWH(0, 0, 260, 900)))
        ..setClaim(#wide,
            const ToastClaim(ToastEdge.left, Rect.fromLTWH(0, 0, 300, 900)));
      expect(controller.insetsFor(layer),
          const EdgeInsets.only(left: 300, bottom: 95));
      controller.dispose();
    });

    test('removing a claim drops its inset', () {
      final controller = ToastController();
      controller.setClaim(#dock,
          const ToastClaim(ToastEdge.bottom, Rect.fromLTWH(12, 805, 776, 83)));
      controller.removeClaim(#dock);
      expect(controller.insetsFor(layer), EdgeInsets.zero);
      controller.dispose();
    });

    test('re-setting an equal claim does not notify', () {
      final controller = ToastController();
      var notified = 0;
      controller.addListener(() => notified++);
      const claim =
          ToastClaim(ToastEdge.bottom, Rect.fromLTWH(12, 805, 776, 83));
      // A second instance carrying equal values, not the same object: two
      // identical `const` literals canonicalise to one, which would let this
      // pass on identity alone even if `ToastClaim` had no `==`.
      final equal =
          ToastClaim(ToastEdge.bottom, Rect.fromLTWH(12, 805, 776, 83));
      expect(identical(claim, equal), isFalse);
      controller.setClaim(#dock, claim);
      controller.setClaim(#dock, equal);
      expect(notified, 1);
      controller.dispose();
    });

    test('writes after dispose are ignored', () {
      fakeAsync((async) {
        final controller = ToastController();
        final entry = controller.show('Saved');
        expect(async.pendingTimers, hasLength(1),
            reason: 'a live countdown, so the check below can fail');
        controller.dispose();
        expect(async.pendingTimers, isEmpty);
        expect(
            () => controller.setClaim(#dock,
                const ToastClaim(ToastEdge.bottom, Rect.fromLTWH(0, 0, 1, 1))),
            returnsNormally);
        expect(() => controller.removeClaim(#dock), returnsNormally);
        expect(() => controller.close(entry.id), returnsNormally);
        expect(() => controller.pause(entry.id), returnsNormally);
        expect(() => controller.resume(entry.id), returnsNormally);
        expect(() => controller.show('late'), returnsNormally);
        expect(async.pendingTimers, isEmpty,
            reason: 'a disposed controller reschedules no countdown');
      });
    });
  });
}
