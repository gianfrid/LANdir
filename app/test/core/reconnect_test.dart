// Tests for session restore: selecting a server persists it, and a fresh
// app start (new ProviderContainer over the same SharedPreferences) reconnects
// to it automatically.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/core/server.dart';
import 'package:landir_app/src/providers/client_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

void main() {
  late String tmpDir;
  late LandirServer server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = Directory.systemTemp.createTempSync('landir_reconnect_').path;
    server = LandirServer(
      ServerConfig(port: 0, uploadDir: tmpDir, insecure: true),
      DirectoryFileSink(tmpDir),
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    Directory(tmpDir).deleteSync(recursive: true);
  });

  SavedServer testServer() =>
      SavedServer(name: 'test', baseUrl: 'http://127.0.0.1:${server.boundPort}/');

  test('selecting a server persists it; a fresh start reconnects', () async {
    // First "app run": add and select the server.
    final first = ProviderContainer();
    final sub1 = first.listen(clientControllerProvider, (_, _) {});
    final server0 = testServer();
    await first.read(clientControllerProvider.notifier).loadPersisted();
    first.read(clientControllerProvider.notifier).addServer(server0.baseUrl);
    await first.read(clientControllerProvider.notifier).selectServer(server0);
    expect(first.read(clientControllerProvider).current?.baseUrl, server0.baseUrl);
    sub1.close();
    first.dispose();

    // Simulate app restart: same persisted values, brand-new container.
    final prefs = await SharedPreferences.getInstance();
    final savedServers = prefs.getString('landir_saved_servers');
    final lastServer = prefs.getString('landir_last_server');
    expect(lastServer, server0.baseUrl);
    SharedPreferences.setMockInitialValues({
      'landir_saved_servers': savedServers!,
      'landir_last_server': lastServer!,
    });

    final second = ProviderContainer();
    final sub2 = second.listen(clientControllerProvider, (_, _) {});
    await second.read(clientControllerProvider.notifier).loadPersisted();
    final state = second.read(clientControllerProvider);
    expect(state.current?.baseUrl, server0.baseUrl);
    expect(state.loading, isFalse);
    expect(state.error, isNull);
    sub2.close();
    second.dispose();
  });

  test('removing the selected server clears the persisted reconnect target',
      () async {
    final container = ProviderContainer();
    final sub = container.listen(clientControllerProvider, (_, _) {});
    final notifier = container.read(clientControllerProvider.notifier);
    final server0 = testServer();
    notifier.addServer(server0.baseUrl);
    await notifier.selectServer(server0);

    notifier.removeServer(server0.baseUrl);
    expect(container.read(clientControllerProvider).current, isNull);
    // The removal is async fire-and-forget; give it a turn.
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('landir_last_server'), isNull);
    sub.close();
    container.dispose();
  });
}
