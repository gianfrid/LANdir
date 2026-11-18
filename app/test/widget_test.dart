// Widget tests for the default (Client) tab, the host view, and the
// wide (desktop) layout. The phone layout opens on the Client tab by
// default; the desktop layout shows a Host/Client toggle plus Downloads.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:landir_app/main.dart';
import 'package:landir_app/src/providers/server_provider.dart';

void main() {
  setUp(() {
    // HostView loads the persisted port choice on creation.
    SharedPreferences.setMockInitialValues({});
  });

  // Phone-sized viewport so the tab layout (not the wide desktop layout
  // with its segmented toggle) is what gets tested.
  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
  }

  testWidgets('app opens on the client tab', (tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(const ProviderScope(child: LandirApp()));

    // Client is the default tab: its empty state is visible without tapping.
    expect(find.textContaining('No servers yet'), findsOneWidget);
    expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
  });

  testWidgets('host tab shows start button and secret mode toggle',
      (tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(const ProviderScope(child: LandirApp()));

    await tester.tap(find.text('Host'));
    await tester.pump();

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

    await tester.tap(find.text('Host'));
    await tester.pump();

    await tester.tap(find.byType(Switch));
    await tester.pump();

    final switchWidget = tester.widget<Switch>(find.byType(Switch));
    expect(switchWidget.value, isFalse);
  });

  testWidgets('host port field defaults to 8000 and commits entered ports',
      (tester) async {
    usePhoneViewport(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container, child: const LandirApp()));

    await tester.tap(find.text('Host'));
    await tester.pump();

    expect(find.text('8000'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '9000');
    await tester.pump();
    expect(find.text('9000'), findsOneWidget);
    // The controller holds the entered port, not just the field's text.
    expect(container.read(serverControllerProvider).requestedPort, 9000);
  });

  testWidgets('invalid port draft is flagged and discards on unfocus',
      (tester) async {
    usePhoneViewport(tester);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container, child: const LandirApp()));

    await tester.tap(find.text('Host'));
    await tester.pump();

    // 99999 is out of range: the field flags it and never commits, so it
    // cannot silently disagree with the port the server would use.
    await tester.enterText(find.byType(TextField), '99999');
    await tester.pump();
    expect(container.read(serverControllerProvider).requestedPort, 8000);
    expect(find.text('0 - 65535'), findsOneWidget);

    // Leaving the field discards the draft and reverts to the committed
    // port.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(find.text('0 - 65535'), findsNothing);
    expect(find.text('8000'), findsOneWidget);
  });

  // Wide viewport so the desktop layout (segmented Host/Client toggle plus
  // Downloads side panel) is what gets tested.
  void useDesktopViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
  }

  testWidgets('desktop layout toggles Host/Client, Downloads beside',
      (tester) async {
    useDesktopViewport(tester);
    await tester.pumpWidget(const ProviderScope(child: LandirApp()));

    // No bottom navigation on desktop; Downloads is a side panel and the
    // Host panel shows first behind the segmented toggle.
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.byType(SegmentedButton<int>), findsOneWidget);
    expect(find.text('Start server'), findsOneWidget);

    // Switching to Client swaps the panel; Downloads stays put.
    await tester.tap(find.text('Client'));
    await tester.pump();
    expect(find.textContaining('No servers yet'), findsOneWidget);
    expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);
  });
}
