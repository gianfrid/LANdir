// M4 tests: sealed transport in LANdirClient against a real Dart host over
// loopback (docs/design/001). The pinned-key client must seal every request
// and refuse unauthenticated responses — never a plaintext fallback.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:landir_app/src/core/client.dart';
import 'package:landir_app/src/core/crypto.dart';
import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/core/server.dart';
import 'package:test/test.dart';

void main() {
  late String tmpDir;
  late HostKey hostKey;
  late LANdirServer server;
  late String baseUrl;
  late LANdirClient client;

  setUpAll(() async {
    tmpDir = Directory.systemTemp.createTempSync('landir_sealed_client_').path;
    final keyDir = Directory.systemTemp.createTempSync('landir_sealed_ckey_');
    addTearDown(() => keyDir.deleteSync(recursive: true));
    hostKey = await HostKeyStore(keyDir.path).loadOrCreate();
    server = LANdirServer(
      ServerConfig(
          port: 0, uploadDir: tmpDir, insecure: false, secretToken: 'tok'),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await server.start();
    baseUrl = 'http://127.0.0.1:${server.boundPort}/tok/';
  });

  tearDownAll(() async {
    client.close();
    await server.stop();
    Directory(tmpDir).deleteSync(recursive: true);
  });

  setUp(() {
    client = LANdirClient(baseUrl, hostKey: hostKey.publicKey);
  });

  tearDown(() {
    client.close();
  });

  test('sealed upload -> sealed listing -> sealed download round trip',
      () async {
    final ok =
        await client.uploadFile('report.txt', Uint8List.fromList(utf8.encode('quarterly')));
    expect(ok, isTrue);

    final files = await client.listDir('');
    expect(files.any((f) => f.name == 'report.txt'), isTrue);

    final bytes = await client.downloadFile('report.txt');
    expect(utf8.decode(bytes), 'quarterly');
  });

  test('sealed listing of a subdirectory', () async {
    Directory('$tmpDir/docs').createSync();
    File('$tmpDir/docs/note.md').writeAsStringSync('hi');
    final entries = await client.listDir('docs');
    expect(entries.any((f) => f.name == 'note.md'), isTrue);
  });

  test('wrong pinned key: listing fails, never falls back to plaintext',
      () async {
    final wrongDir = Directory.systemTemp.createTempSync('landir_wrong_');
    addTearDown(() => wrongDir.deleteSync(recursive: true));
    final wrongHost = await HostKeyStore(wrongDir.path).loadOrCreate();
    final evil = LANdirClient(baseUrl, hostKey: wrongHost.publicKey);
    addTearDown(() => evil.close());
    // The server cannot authenticate the envelope's response to us: the
    // response either 400s or fails to open — both surface as exceptions.
    expect(() => evil.listDir(''), throwsA(isA<HttpException>()));
  });

  test('keyless client against keyless host still works (plaintext mode)',
      () async {
    final plain = LANdirServer(
      ServerConfig(
          port: 0, uploadDir: tmpDir, insecure: false, secretToken: 'plain'),
      DirectoryFileSink(tmpDir),
    );
    await plain.start();
    addTearDown(() => plain.stop());
    final c = LANdirClient('http://127.0.0.1:${plain.boundPort}/plain/');
    addTearDown(() => c.close());
    final ok = await c.uploadFile('plain.txt', Uint8List.fromList(utf8.encode('p')));
    expect(ok, isTrue);
    final files = await c.listDir('');
    expect(files.any((f) => f.name == 'plain.txt'), isTrue);
  });
}
