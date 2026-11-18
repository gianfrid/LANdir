// Provider-level tests for the user-selectable host port (Requested port:
// 0 means the host picks a free dynamic-range port itself).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landir_app/src/core/server.dart';
import 'package:landir_app/src/providers/server_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ServerController notifierOf(ProviderContainer container) =>
      container.read(serverControllerProvider.notifier);

  test('port defaults to 8000 and is selectable while stopped', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = notifierOf(container);

    expect(container.read(serverControllerProvider).requestedPort, 8000);
    notifier.setPort(9000);
    expect(container.read(serverControllerProvider).requestedPort, 9000);
    // 0 is allowed and means "pick a free port for me".
    notifier.setPort(0);
    expect(container.read(serverControllerProvider).requestedPort, 0);
  });

  test('out-of-range ports are rejected', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = notifierOf(container);

    notifier.setPort(65536);
    expect(container.read(serverControllerProvider).requestedPort, 8000);
    notifier.setPort(-1);
    expect(container.read(serverControllerProvider).requestedPort, 8000);
  });

  test('toggling insecure mode preserves the selected port', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = notifierOf(container);

    notifier.setPort(9000);
    notifier.toggleInsecure();
    final state = container.read(serverControllerProvider);
    expect(state.requestedPort, 9000);
    expect(state.insecure, isTrue);
  });

  test('stop() keeps the port choice for the next start', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = notifierOf(container);

    notifier.setPort(9000);
    // A regression to `const ServerState()` here would reset to 8000.
    expect(notifier.stop(), completes);
    final state = container.read(serverControllerProvider);
    expect(state.running, isFalse);
    expect(state.requestedPort, 9000);
  });

  test('setPort is ignored while the server is running', () {
    final container = ProviderContainer(
      overrides: [serverControllerProvider.overrideWith(_Running.new)],
    );
    addTearDown(container.dispose);
    notifierOf(container).setPort(9000);
    final state = container.read(serverControllerProvider);
    expect(state.running, isTrue);
    expect(state.requestedPort, 8000); // untouched
    expect(state.port, 4242); // the "bound" port of the fake
  });

  test('setPort persists the choice across app restarts', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    notifierOf(container).setPort(9100);
    await Future<void>.delayed(Duration.zero); // flush the unawaited write

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('requested_port'), 9100);
  });

  test('loadPersistedPort restores a saved choice', () async {
    SharedPreferences.setMockInitialValues({'requested_port': 9001});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await notifierOf(container).loadPersistedPort();
    expect(
        container.read(serverControllerProvider).requestedPort, 9001);
  });

  test('loadPersistedPort ignores a corrupt stored value', () async {
    SharedPreferences.setMockInitialValues({'requested_port': 70000});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await notifierOf(container).loadPersistedPort();
    expect(
        container.read(serverControllerProvider).requestedPort, 8000);
  });

  test('the advertised URL carries the bound port in both modes', () {
    // After a fallback the URL must advertise the port actually bound,
    // not the one that was requested (GLOSSARY: Advertised/Bound port).
    expect(advertisedUrl('192.168.1.50', 53123, 'tok'),
        'http://192.168.1.50:53123/tok/');
    expect(advertisedUrl('192.168.1.50', 53123, null),
        'http://192.168.1.50:53123/');
  });

  test('isValidPort accepts 0-65535 and nothing else', () {
    for (final p in [0, 1, 8000, 65535]) {
      expect(ServerConfig.isValidPort(p), isTrue, reason: 'port $p');
    }
    for (final p in [-1, 65536, 99999]) {
      expect(ServerConfig.isValidPort(p), isFalse, reason: 'port $p');
    }
  });
}

/// A controller that reports a running server without binding anything.
class _Running extends ServerController {
  @override
  ServerState build() => const ServerState(running: true, port: 4242);
}
