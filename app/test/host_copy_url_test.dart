// Widget test: the host view's copy button puts the advertised URL on the
// clipboard and confirms with a snackbar (so the URL can be pasted on a
// device that cannot scan the QR code).

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landir_app/main.dart';
import 'package:landir_app/src/providers/server_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('copy button copies the advertised URL', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final container = ProviderContainer(
      overrides: [serverControllerProvider.overrideWith(_Running.new)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container, child: const LANdirApp()));
    await tester.pump();

    // The Host tab holds the running view (QR code, URL, copy button).
    await tester.tap(find.text('Host'));
    await tester.pump();

    expect(find.text(_Running.url), findsOneWidget);

    await tester.tap(find.byTooltip('Copy URL'));
    await tester.pump();

    final copy = calls.singleWhere((c) => c.method == 'Clipboard.setData');
    expect((copy.arguments as Map)['text'], _Running.url);
    expect(find.text('URL copied'), findsOneWidget);
  });
}

/// A controller that reports a running server without binding anything.
class _Running extends ServerController {
  static const url = 'http://192.168.1.50:4242/tok/';

  @override
  ServerState build() => const ServerState(
        running: true,
        port: 4242,
        url: url,
        token: 'tok',
      );
}
