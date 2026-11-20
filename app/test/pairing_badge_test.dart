// M5 widget tests: pairing badge on the server list (Encrypted vs
// Not encrypted) and the rescan-changed-key dialog.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landir_app/main.dart';
import 'package:landir_app/src/providers/client_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
  }

  testWidgets('pinned server shows Encrypted, keyless shows Not encrypted',
      (tester) async {
    usePhoneViewport(tester);
    // Seed the registry: one pinned, one keyless.
    final prefs = await SharedPreferences.getInstance();
    // base64url of 32 bytes (a real X25519 public key length).
    final key = base64Url.encode(List.filled(32, 7)).replaceAll('=', '');
    await prefs.setString(
      'landir_saved_servers',
      jsonEncode({
        'v': 1,
        'servers': [
          {
            'name': '192.168.1.10',
            'baseUrl': 'http://192.168.1.10:8000/tokA/',
            'hostKey': key,
          },
          {
            'name': '192.168.1.20',
            'baseUrl': 'http://192.168.1.20:8000/tokB/',
          },
        ],
      }),
    );
    await tester.pumpWidget(const ProviderScope(child: LandirApp()));
    await tester.pumpAndSettle();

    expect(find.text('Encrypted'), findsOneWidget);
    expect(find.text('Not encrypted'), findsOneWidget);
  });

  testWidgets('changed host key shows the re-pair dialog; keeping the old key cancels',
      (tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(const ProviderScope(child: LandirApp()));
    await tester.pumpAndSettle();

    // Drive the provider directly: pin a server, then rescan a different key.
    final container = ProviderScope.containerOf(tester.element(find.byType(LandirApp)));
    final notifier = container.read(clientControllerProvider.notifier);
    final keyA = base64Url.encode(List.filled(32, 1)).replaceAll('=', '');
    final keyB = base64Url.encode(List.filled(32, 2)).replaceAll('=', '');
    notifier.addServer('http://192.168.1.10:8000/tokA/#k=$keyA');
    notifier.addServer('http://192.168.1.10:8000/tokB/#k=$keyB');
    await tester.pumpAndSettle();

    expect(find.text('Server key changed'), findsOneWidget);
    expect(find.text('Re-pair'), findsOneWidget);

    // Decline: conflict cleared, pin unchanged.
    await tester.tap(find.text('Keep old key'));
    await tester.pumpAndSettle();
    final state = container.read(clientControllerProvider);
    expect(state.pendingKeyConflict, isNull);
    expect(state.servers.single.hostKey, keyA);
  });
}
