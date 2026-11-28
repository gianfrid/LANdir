// M3 tests: client pinning (design 001). SavedServer.hostKey, #k= parsing on
// scan, registry versioning/migration, and rescan-changed-key blocking.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  test('keyless rescan of a pinned host:port blocks (no silent downgrade)',
      () async {
    final keyA = base64Url.encode(List.filled(32, 1)).replaceAll('=', '');
    controller.addServer('http://192.168.1.10:8000/tokA/#k=$keyA');
    final pinned = stateOf(container).servers.single;

    // Same host:port, QR without #k= (or a typed URL, which drops the
    // fragment): must not silently replace the pin with a keyless entry.
    controller.addServer('http://192.168.1.10:8000/tokB/');
    final conflict = stateOf(container).pendingKeyConflict;
    expect(conflict, isNotNull);
    expect(stateOf(container).servers.single.hostKey, pinned.hostKey);

    // Decline: the pin survives.
    controller.cancelRekey();
    expect(stateOf(container).pendingKeyConflict, isNull);
    expect(stateOf(container).servers.single.hostKey, pinned.hostKey);

    // Explicit confirmation is the only way to downgrade.
    controller.addServer('http://192.168.1.10:8000/tokB/');
    controller.confirmRekey();
    expect(stateOf(container).servers.single.hostKey, isNull);
    expect(stateOf(container).servers.single.baseUrl,
        'http://192.168.1.10:8000/tokB/');

    // Keyless -> keyed (host upgraded) is the one silent transition.
    controller.addServer('http://192.168.1.10:8000/tokC/#k=$keyA');
    expect(stateOf(container).pendingKeyConflict, isNull);
    expect(stateOf(container).servers.single.hostKey, keyA);
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
    final server = LANdirServer(
      ServerConfig(
          port: 0,
          uploadDir: tmpDir,
          insecure: true,
          encrypted: true),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await server.start();
    addTearDown(() => server.stop());

    controller.addServer(
        'http://127.0.0.1:${server.boundPort}/${keyFragment()}');
    await controller.selectServer(stateOf(container).servers.first);
    expect(stateOf(container).error, isNull);
    expect(stateOf(container).files.any((f) => f.name == 'secret.txt'), isTrue);
  });

  test('pinned client against a host with a different key fails (no fallback)',
      () async {
    final server = LANdirServer(
      ServerConfig(
          port: 0,
          uploadDir: tmpDir,
          insecure: true,
          encrypted: true),
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
        'http://127.0.0.1:${server.boundPort}/$wrongFrag');
    await controller.selectServer(stateOf(container).servers.first);
    // Sealed listing failed, not plaintext — and the stale pin can never
    // succeed, so the host is dropped like a 404, not kept as dead weight.
    final state = stateOf(container);
    expect(state.error, isNotNull);
    expect(state.error, contains('pinned key'));
    expect(state.files, isEmpty);
    expect(state.servers, isEmpty);
    expect(state.current, isNull);
    expect(state.removedServerUrl, 'http://127.0.0.1:${server.boundPort}/');
    expect(state.removedServerReason, contains('Re-scan'));

    // The removal is persisted, so a fresh app start does not resurrect it.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('landir_saved_servers');
    expect((jsonDecode(raw!) as Map<String, dynamic>)['servers'], isEmpty);
  });

  test('a sealed folder that disappears keeps the host registered', () async {
    File('$tmpDir/secret.txt').writeAsStringSync('s3cret');
    Directory('$tmpDir/gone').createSync();
    File('$tmpDir/gone/inner.txt').writeAsStringSync('inner');
    final server = LANdirServer(
      ServerConfig(
          port: 0,
          uploadDir: tmpDir,
          insecure: true,
          encrypted: true),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await server.start();
    addTearDown(() => server.stop());

    controller.addServer(
        'http://127.0.0.1:${server.boundPort}/${keyFragment()}');
    final entry = stateOf(container).servers.single;
    await controller.selectServer(entry);
    await controller.navigateInto('gone');
    expect(stateOf(container).files.map((f) => f.name), contains('inner.txt'));

    // The folder is deleted on the host: the sealed listing 404s, but the
    // root still answers — only the folder is gone, not the host.
    Directory('$tmpDir/gone').deleteSync(recursive: true);
    await controller.refresh();
    final state = stateOf(container);
    expect(state.error, contains('folder not found'));
    expect(state.servers.map((s) => s.baseUrl), contains(entry.baseUrl));
    expect(state.current?.baseUrl, entry.baseUrl);
    expect(state.removedServerUrl, isNull);
  });

  // The mid-session re-key: the pin worked when the host was selected, then
  // the host restarted with a NEW key on the same port. The next sealed
  // exchange can no longer authenticate, so the host must be dropped.
  Future<SavedServer> selectPinnedThenRekey() async {
    final serverA = LANdirServer(
      ServerConfig(
          port: 0, uploadDir: tmpDir, insecure: true, encrypted: true),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await serverA.start();
    controller.addServer(
        'http://127.0.0.1:${serverA.boundPort}/${keyFragment()}');
    final entry = stateOf(container).servers.single;
    await controller.selectServer(entry);
    expect(stateOf(container).current?.baseUrl, entry.baseUrl);

    final keyDir2 = Directory.systemTemp.createTempSync('landir_rekey_');
    addTearDown(() => keyDir2.deleteSync(recursive: true));
    final key2 = await HostKeyStore(keyDir2.path).loadOrCreate();
    final port = serverA.boundPort;
    await serverA.stop();
    // Re-bind the SAME port for the restarted host. The bind can lose a
    // race with the old listener's teardown — the server then silently
    // falls back to a random port, which the client's pinned URL would
    // never reach — so retry until the port really matches.
    late final LANdirServer serverB;
    var attempts = 0;
    while (true) {
      final candidate = LANdirServer(
        ServerConfig(
            port: port, uploadDir: tmpDir, insecure: true, encrypted: true),
        DirectoryFileSink(tmpDir),
        hostKey: key2,
      );
      await candidate.start();
      if (candidate.boundPort == port) {
        serverB = candidate;
        break;
      }
      await candidate.stop();
      if (++attempts > 25) {
        fail('could not re-bind port $port for the re-keyed host');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    addTearDown(() => serverB.stop());
    return entry;
  }

  test('a host that re-keys mid-session is dropped on upload', () async {
    final entry = await selectPinnedThenRekey();

    // The first request dies on the stale keep-alive socket to the old
    // process: a transient transport error, so the host stays registered.
    final first = await controller.uploadFile(
        'x.txt', Uint8List.fromList(utf8.encode('x')));
    expect(first, isFalse);
    var midState = stateOf(container);
    expect(midState.error, contains('Upload error'));
    expect(
        midState.servers.map((s) => s.baseUrl), contains(entry.baseUrl));

    // The retry reaches the re-keyed host: the sealed upload cannot
    // authenticate, the pin re-check confirms it is stale, and the host
    // is dropped.
    final second = await controller.uploadFile(
        'x.txt', Uint8List.fromList(utf8.encode('x')));
    expect(second, isFalse);
    final state = stateOf(container);
    expect(state.servers, isEmpty);
    expect(state.current, isNull);
    expect(state.removedServerUrl, entry.baseUrl);
    expect(state.removedServerReason, contains('pinned key'));
    expect(state.error, contains('pinned key'));
  });

  test('a host that re-keys mid-session is dropped on download', () async {
    final entry = await selectPinnedThenRekey();

    // As above: the first request is a transient stale-socket error...
    final first = await controller.downloadFile('whatever.txt');
    expect(first, isNull);
    var midState = stateOf(container);
    expect(midState.error, contains('Download error'));
    expect(
        midState.servers.map((s) => s.baseUrl), contains(entry.baseUrl));

    // ...and the retry confirms the stale pin and drops the host.
    final second = await controller.downloadFile('whatever.txt');
    expect(second, isNull);
    final state = stateOf(container);
    expect(state.servers, isEmpty);
    expect(state.current, isNull);
    expect(state.removedServerUrl, entry.baseUrl);
    expect(state.removedServerReason, contains('pinned key'));
  });

  test('a rejected sealed upload keeps the host registered', () async {
    final server = LANdirServer(
      ServerConfig(
          port: 0,
          uploadDir: tmpDir,
          insecure: true,
          encrypted: true,
          maxUploadBytes: 8),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await server.start();
    addTearDown(() => server.stop());

    controller.addServer(
        'http://127.0.0.1:${server.boundPort}/${keyFragment()}');
    final entry = stateOf(container).servers.single;
    await controller.selectServer(entry);

    // 413 over the size limit: the pin is confirmed alive by the sealed
    // root listing, so this is a plain rejection — not a stale-pin drop.
    final ok = await controller.uploadFile(
        'big.txt', Uint8List.fromList(List.filled(64, 0x41)));
    expect(ok, isFalse);
    final state = stateOf(container);
    expect(state.error, contains('Upload failed'));
    expect(state.servers.map((s) => s.baseUrl), contains(entry.baseUrl));
    expect(state.current?.baseUrl, entry.baseUrl);
    expect(state.removedServerUrl, isNull);
  });

  test('a sealed download of a missing file keeps the host registered',
      () async {
    File('$tmpDir/secret.txt').writeAsStringSync('s3cret');
    final server = LANdirServer(
      ServerConfig(
          port: 0, uploadDir: tmpDir, insecure: true, encrypted: true),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await server.start();
    addTearDown(() => server.stop());

    controller.addServer(
        'http://127.0.0.1:${server.boundPort}/${keyFragment()}');
    final entry = stateOf(container).servers.single;
    await controller.selectServer(entry);

    // The file is missing, but the host opened our envelope and answered
    // a path-level 404: the pin works, the host stays.
    final bytes = await controller.downloadFile('missing.txt');
    expect(bytes, isNull);
    final state = stateOf(container);
    expect(state.error, contains('Download error'));
    expect(state.error, contains('file not found'));
    expect(state.servers.map((s) => s.baseUrl), contains(entry.baseUrl));
    expect(state.current?.baseUrl, entry.baseUrl);
    expect(state.removedServerUrl, isNull);

    // And it still works afterwards.
    await controller.refresh();
    expect(stateOf(container).files.any((f) => f.name == 'secret.txt'),
        isTrue);
  });
}
