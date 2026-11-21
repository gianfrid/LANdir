// Provider-level test for client directory navigation logic.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/core/server.dart';
import 'package:landir_app/src/providers/client_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late String tmpDir;
  late LANdirServer server;
  late int port;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = Directory.systemTemp.createTempSync('landir_nav_').path;
    Directory('$tmpDir/reports/2025').createSync(recursive: true);
    File('$tmpDir/reports/q3.txt').writeAsStringSync('q3');
    File('$tmpDir/reports/2025/q4.txt').writeAsStringSync('q4');
    File('$tmpDir/top.txt').writeAsStringSync('top');
    server = LANdirServer(
      ServerConfig(port: 0, uploadDir: tmpDir, insecure: true),
      DirectoryFileSink(tmpDir),
    );
    await server.start();
    port = server.boundPort;
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await server.stop();
    Directory(tmpDir).deleteSync(recursive: true);
  });

  test('navigateInto / navigateUp walk the directory tree', () async {
    // Keep the autoDispose provider alive for the duration of the test.
    final sub = container.listen(clientControllerProvider, (prev, next) {});
    addTearDown(sub.close);
    final notifier = container.read(clientControllerProvider.notifier);
    await notifier.selectServer(
        SavedServer(name: 'test', baseUrl: 'http://127.0.0.1:$port/'));
    expect(container.read(clientControllerProvider).currentPath, '');
    expect(container.read(clientControllerProvider).files.map((f) => f.name),
        containsAll(['top.txt', 'reports']));

    await notifier.navigateInto('reports');
    var state = container.read(clientControllerProvider);
    expect(state.currentPath, 'reports');
    expect(state.files.map((f) => f.name), containsAll(['q3.txt', '2025']));

    await notifier.navigateInto('2025');
    state = container.read(clientControllerProvider);
    expect(state.currentPath, 'reports/2025');
    expect(state.files.map((f) => f.name), contains('q4.txt'));

    await notifier.navigateUp();
    state = container.read(clientControllerProvider);
    expect(state.currentPath, 'reports');

    await notifier.navigateUp();
    state = container.read(clientControllerProvider);
    expect(state.currentPath, '');
    expect(state.files.map((f) => f.name), contains('top.txt'));

    // navigateUp at root stays at root
    await notifier.navigateUp();
    expect(container.read(clientControllerProvider).currentPath, '');
  });

  test('404 from the server removes it from the registry', () async {
    SharedPreferences.setMockInitialValues({});
    final sub = container.listen(clientControllerProvider, (prev, next) {});
    addTearDown(sub.close);
    final notifier = container.read(clientControllerProvider.notifier);

    const live = SavedServer(name: 'live', baseUrl: 'http://127.0.0.1:1/');
    // Insecure server: any token-prefixed path is a 404, which is exactly
    // what a client sees after the server restarted with a new token.
    final dead =
        SavedServer(name: 'dead', baseUrl: 'http://127.0.0.1:$port/stale/');
    notifier.addServer(live.baseUrl);
    notifier.addServer(dead.baseUrl);
    expect(container.read(clientControllerProvider).servers.length, 2);

    // Selecting a server that 404s drops it and deselects it.
    await notifier.selectServer(dead);
    var state = container.read(clientControllerProvider);
    expect(state.servers.map((s) => s.baseUrl), isNot(contains(dead.baseUrl)));
    expect(state.servers.map((s) => s.baseUrl), contains(live.baseUrl));
    expect(state.current, isNull);
    expect(state.removedServerUrl, dead.baseUrl);
    expect(state.error, contains('no longer exists'));

    // The removal is persisted.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('landir_saved_servers'), isNot(contains('stale')));

    notifier.acknowledgeRemovedServer();
    expect(container.read(clientControllerProvider).removedServerUrl, isNull);

    // A 404 on refresh (server stopped mid-session) does the same.
    await notifier.selectServer(dead);
    expect(container.read(clientControllerProvider).current, isNull);
  });

  test('a 404 on download keeps the server registered', () async {
    SharedPreferences.setMockInitialValues({});
    final sub = container.listen(clientControllerProvider, (prev, next) {});
    addTearDown(sub.close);
    final notifier = container.read(clientControllerProvider.notifier);

    final server =
        SavedServer(name: 'live', baseUrl: 'http://127.0.0.1:$port/');
    notifier.addServer(server.baseUrl);
    await notifier.selectServer(server);
    expect(container.read(clientControllerProvider).current, isNotNull);

    // A missing file is a 404, but that only means the file is gone.
    final bytes = await notifier.downloadFile('missing.txt');
    final state = container.read(clientControllerProvider);
    expect(bytes, isNull);
    expect(state.error, contains('Download error'));
    expect(state.removedServerUrl, isNull);
    expect(state.servers.map((s) => s.baseUrl), contains(server.baseUrl));
    expect(state.current?.baseUrl, server.baseUrl);

    // The server still works afterwards.
    await notifier.refresh();
    expect(container.read(clientControllerProvider).current, isNotNull);
    expect(container.read(clientControllerProvider).files.map((f) => f.name),
        contains('top.txt'));
  });

  test('a non-LAN address is held as pending until confirmed', () async {
    SharedPreferences.setMockInitialValues({});
    final sub = container.listen(clientControllerProvider, (prev, next) {});
    addTearDown(sub.close);
    final notifier = container.read(clientControllerProvider.notifier);

    // A public IP (TEST-NET-3) is not added directly.
    notifier.addServer('http://203.0.113.7:8000/');
    var state = container.read(clientControllerProvider);
    expect(state.pendingNonLanServer?.baseUrl, 'http://203.0.113.7:8000/');
    expect(state.servers, isEmpty);

    // Confirming adds and persists it, clearing the pending entry.
    notifier.confirmPendingNonLanServer();
    state = container.read(clientControllerProvider);
    expect(state.pendingNonLanServer, isNull);
    expect(state.servers.map((s) => s.baseUrl),
        contains('http://203.0.113.7:8000/'));
    // The persist write is fire-and-forget; let it land.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('landir_saved_servers'), contains('203.0.113.7'));
  });

  test('a declined non-LAN server is discarded', () async {
    SharedPreferences.setMockInitialValues({});
    final sub = container.listen(clientControllerProvider, (prev, next) {});
    addTearDown(sub.close);
    final notifier = container.read(clientControllerProvider.notifier);

    notifier.addServer('http://evil.example.com/');
    expect(container.read(clientControllerProvider).pendingNonLanServer,
        isNotNull);

    notifier.cancelPendingNonLanServer();
    final state = container.read(clientControllerProvider);
    expect(state.pendingNonLanServer, isNull);
    expect(state.servers, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('landir_saved_servers'), isNull);
  });

  test('a LAN address is added directly with no pending entry', () async {
    SharedPreferences.setMockInitialValues({});
    final sub = container.listen(clientControllerProvider, (prev, next) {});
    addTearDown(sub.close);
    final notifier = container.read(clientControllerProvider.notifier);

    notifier.addServer('http://192.168.1.50:8000/');
    final state = container.read(clientControllerProvider);
    expect(state.pendingNonLanServer, isNull);
    expect(
        state.servers.map((s) => s.baseUrl), contains('http://192.168.1.50:8000/'));
  });

  test('shouldLeaveBrowser keys on the current transition', () {
    const s = SavedServer(name: 's', baseUrl: 'http://x/');
    const browsing = ClientState(current: s);
    const empty = ClientState();

    // Deselected while browsing (manual delete or 404 drop) -> leave.
    expect(shouldLeaveBrowser(browsing, empty), isTrue);
    // Never had a server, just selected one, or nothing changed -> stay.
    expect(shouldLeaveBrowser(null, empty), isFalse);
    expect(shouldLeaveBrowser(empty, browsing), isFalse);
    expect(shouldLeaveBrowser(browsing, browsing), isFalse);
    // The removed-server flag alone must not drive the pop: it is one-shot
    // and another listener (the client view) may acknowledge it first.
    const flagged = ClientState(removedServerUrl: 'http://x/');
    expect(shouldLeaveBrowser(flagged, flagged), isFalse);
  });

  test('a successful upload keeps the server registered', () async {
    SharedPreferences.setMockInitialValues({});
    final sub = container.listen(clientControllerProvider, (prev, next) {});
    addTearDown(sub.close);
    final notifier = container.read(clientControllerProvider.notifier);

    final server =
        SavedServer(name: 'live', baseUrl: 'http://127.0.0.1:$port/');
    notifier.addServer(server.baseUrl);
    await notifier.selectServer(server);

    final ok = await notifier.uploadFile(
        'new.txt', Uint8List.fromList([104, 105]));
    expect(ok, isTrue);
    final state = container.read(clientControllerProvider);
    expect(state.removedServerUrl, isNull);
    expect(state.servers.map((s) => s.baseUrl), contains(server.baseUrl));
    expect(state.files.map((f) => f.name), contains('new.txt'));
  });

  test('a host that dies mid-session is kept on transient failures',
      () async {
    SharedPreferences.setMockInitialValues({});
    final sub = container.listen(clientControllerProvider, (prev, next) {});
    addTearDown(sub.close);
    final notifier = container.read(clientControllerProvider.notifier);

    final entry =
        SavedServer(name: 'live', baseUrl: 'http://127.0.0.1:$port/');
    notifier.addServer(entry.baseUrl);
    await notifier.selectServer(entry);

    // The host dies mid-session: uploads and refreshes now fail with a
    // connection error, which must not be mistaken for a 404 (gone).
    await server.stop();
    final ok = await notifier.uploadFile(
        'new.txt', Uint8List.fromList([104, 105]));
    expect(ok, isFalse);
    var state = container.read(clientControllerProvider);
    expect(state.error, contains('Upload error'));
    expect(state.removedServerUrl, isNull);
    expect(state.servers.map((s) => s.baseUrl), contains(entry.baseUrl));
    expect(state.current?.baseUrl, entry.baseUrl);

    await notifier.refresh();
    state = container.read(clientControllerProvider);
    expect(state.error, contains('Refresh failed'));
    expect(state.removedServerUrl, isNull);
    expect(state.servers.map((s) => s.baseUrl), contains(entry.baseUrl));
  });
}
