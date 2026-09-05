import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/presentation/widgets/banner_button.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool isLoading = false,
  VoidCallback? onPressed,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BannerButton(
          label: 'Update',
          color: AppColors.info,
          isLoading: isLoading,
          onPressed: onPressed ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('shows its label and calls back when tapped', (tester) async {
    var taps = 0;
    await _pump(tester, onPressed: () => taps++);

    expect(find.text('Update'), findsOneWidget);
    await tester.tap(find.byType(BannerButton));
    expect(taps, 1);
  });

  testWidgets('while loading it spins instead of labelling, and is inert',
      (tester) async {
    var taps = 0;
    await _pump(tester, isLoading: true, onPressed: () => taps++);

    expect(find.text('Update'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byType(BannerButton));
    expect(taps, 0);
  });
}
