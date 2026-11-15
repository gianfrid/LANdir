// Widget tests for the host view.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:landir_app/main.dart';

void main() {
  // Phone-sized viewport so the tab layout (not the wide 3-panel desktop
  // layout) is what gets tested.
  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
  }

  testWidgets('idle view shows start button and secret mode toggle',
      (tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(const ProviderScope(child: LandirApp()));

    expect(find.text('Start server'), findsOneWidget);
    expect(find.text('Secret URL mode'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    // Secret mode is on by default: switch is on
    final switchWidget = tester.widget<Switch>(find.byType(Switch));
    expect(switchWidget.value, isTrue);
  });

  testWidgets('toggling the switch flips insecure mode', (tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(const ProviderScope(child: LandirApp()));

    await tester.tap(find.byType(Switch));
    await tester.pump();

    final switchWidget = tester.widget<Switch>(find.byType(Switch));
    expect(switchWidget.value, isFalse);
  });

  testWidgets('client tab shows empty state with scan prompt', (tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(const ProviderScope(child: LandirApp()));

    // Switch to Client tab
    await tester.tap(find.text('Client'));
    await tester.pump();

    expect(find.textContaining('No servers yet'), findsOneWidget);
    expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
  });
}
