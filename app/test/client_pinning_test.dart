// M3 tests: client pinning (design 001). SavedServer.hostKey, #k= parsing on
// scan, registry versioning/migration, and rescan-changed-key blocking.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landir_app/src/core/crypto.dart';
import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/core/server.dart';
import 'package:landir_app/src/providers/client_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

ClientController controllerOf(ProviderContainer c) =>
    c.read(clientControllerProvider.notifier);
ClientState stateOf(ProviderContainer c) => c.read(clientControllerProvider);

void main() {
  late String tmpDir;
  late HostKey hostKey;
  late ProviderContainer container;
  late ClientController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = Directory.systemTemp.createTempSync('landir_pin_').path;
    final keyDir = Directory.systemTemp.createTempSync('landir_pin_key_');
    addTearDown(() => keyDir.deleteSync(recursive: true));
    hostKey = await HostKeyStore(keyDir.path).loadOrCreate();
    container = ProviderContainer();
    // Keep the autoDispose provider alive for the duration of the test.
    final sub = container.listen(clientControllerProvider, (prev, next) {});
    addTearDown(sub.close);
    controller = controllerOf(container);
  });

  tearDown(() {
    container.dispose();
    Directory(tmpDir).deleteSync(recursive: true);
  });

  String keyFragment() =>
      '#k=${base64Url.encode(hostKey.publicKey).replaceAll('=', '')}';

  test('scan with #k= pins the host key; registry persists v1 format', () async {
    controller.addServer('http://192.168.1.10:8000/tok123/${keyFragment()}');
    expect(stateOf(container).servers, hasLength(1));
    expect(stateOf(container).servers.first.hostKey, isNotNull);
    expect(stateOf(container).servers.first.hostKeyBytes, hostKey.publicKey);
    expect(stateOf(container).servers.first.baseUrl, 'http://192.168.1.10:8000/tok123/');

    // _persistServers is fire-and-forget; let it land before reading prefs.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('landir_saved_servers')!;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    expect(decoded['v'], 1);
    expect((decoded['servers'] as List<dynamic>).first['hostKey'],
        stateOf(container).servers.first.hostKey);
  });

  test('pin round-trips through loadPersisted', () async {
    controller.addServer('http://192.168.1.10:8000/tok/${keyFragment()}');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final container2 = ProviderContainer();
    final sub2 = container2.listen(clientControllerProvider, (p, n) {});
    addTearDown(sub2.close);
    addTearDown(container2.dispose);
    await container2
        .read(clientControllerProvider.notifier)
        .loadPersisted();
    final servers = container2.read(clientControllerProvider).servers;
    expect(servers, hasLength(1));
    expect(servers.first.hostKeyBytes, hostKey.publicKey);
  });

  test('legacy bare-list registry migrates with null hostKey', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'landir_saved_servers',
      jsonEncode([
        {'name': '192.168.1.10', 'baseUrl': 'http://192.168.1.10:8000/old/'},
      ]),
    );
    await controller.loadPersisted();
    expect(stateOf(container).servers, hasLength(1));
    expect(stateOf(container).servers.first.hostKey, isNull);
  });

  test('keyless host scan yields null hostKey (badge state)', () async {
    controller.addServer('http://192.168.1.20:8000/abc/');
    expect(stateOf(container).servers, hasLength(1));
    expect(stateOf(container).servers.first.hostKey, isNull);
  });

  test('rescan with a different key for the same host:port blocks and re-pairs explicitly',
      () async {
    controller.addServer('http://192.168.1.10:8000/tokA/${keyFragment()}');
    final before = stateOf(container).servers.first;

    final otherDir = Directory.systemTemp.createTempSync('landir_other_');
    addTearDown(() => otherDir.deleteSync(recursive: true));
    final otherKey = await HostKeyStore(otherDir.path).loadOrCreate();
    final otherFrag =
        '#k=${base64Url.encode(otherKey.publicKey).replaceAll('=', '')}';

    // Same host:port, different token AND different key -> conflict.
    controller.addServer('http://192.168.1.10:8000/tokB/$otherFrag');
    expect(stateOf(container).pendingKeyConflict, isNotNull);
    expect(stateOf(container).pendingKeyConflict!.existing.baseUrl, before.baseUrl);
    expect(stateOf(container).servers, hasLength(1)); // unchanged while blocked
    expect(stateOf(container).servers.first.hostKey, before.hostKey);

    // Cancel: conflict cleared, pin untouched.
    controller.cancelRekey();
    expect(stateOf(container).pendingKeyConflict, isNull);
    expect(stateOf(container).servers.first.hostKey, before.hostKey);

    // Rescan again, then confirm: pin updated to the new key.
    controller.addServer('http://192.168.1.10:8000/tokB/$otherFrag');
    expect(stateOf(container).pendingKeyConflict, isNotNull);
    controller.confirmRekey();
    expect(stateOf(container).pendingKeyConflict, isNull);
    expect(stateOf(container).servers, hasLength(1));
    expect(stateOf(container).servers.first.hostKeyBytes, otherKey.publicKey);
    expect(stateOf(container).servers.first.baseUrl, 'http://192.168.1.10:8000/tokB/');
  });

  test('rescan with the same key for the same host:port just refreshes the token',
      () async {
    controller.addServer('http://192.168.1.10:8000/tokA/${keyFragment()}');
    controller.addServer('http://192.168.1.10:8000/tokB/${keyFragment()}');
    expect(stateOf(container).pendingKeyConflict, isNull);
    expect(stateOf(container).servers, hasLength(1));
    expect(stateOf(container).servers.first.baseUrl, 'http://192.168.1.10:8000/tokB/');
    expect(stateOf(container).servers.first.hostKeyBytes, hostKey.publicKey);
  });

  test('pinned client lists a sealed host over loopback', () async {
    File('$tmpDir/secret.txt').writeAsStringSync('s3cret');
    final server = LandirServer(
      ServerConfig(
          port: 0, uploadDir: tmpDir, insecure: false, secretToken: 'tok'),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await server.start();
    addTearDown(() => server.stop());

    controller.addServer(
        'http://127.0.0.1:${server.boundPort}/tok/${keyFragment()}');
    await controller.selectServer(stateOf(container).servers.first);
    expect(stateOf(container).error, isNull);
    expect(stateOf(container).files.any((f) => f.name == 'secret.txt'), isTrue);
  });

  test('pinned client against a host with a different key fails (no fallback)',
      () async {
    final server = LandirServer(
      ServerConfig(
          port: 0, uploadDir: tmpDir, insecure: false, secretToken: 'tok'),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await server.start();
    addTearDown(() => server.stop());

    final wrongDir = Directory.systemTemp.createTempSync('landir_wrongkey_');
    addTearDown(() => wrongDir.deleteSync(recursive: true));
    final wrongKey = await HostKeyStore(wrongDir.path).loadOrCreate();
    final wrongFrag =
        '#k=${base64Url.encode(wrongKey.publicKey).replaceAll('=', '')}';

    controller.addServer(
        'http://127.0.0.1:${server.boundPort}/tok/$wrongFrag');
    await controller.selectServer(stateOf(container).servers.first);
    expect(stateOf(container).error, isNotNull); // sealed listing failed, not plaintext
    expect(stateOf(container).files, isEmpty);
  });
}
