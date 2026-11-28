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
    // Disentangled semantics (ADR 0003): encrypted host = key only, fixed
    // root paths, no token.
    server = LANdirServer(
      ServerConfig(
          port: 0, uploadDir: tmpDir, insecure: true, encrypted: true),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await server.start();
    baseUrl = 'http://127.0.0.1:${server.boundPort}/';
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
    // sealed exchange fails — surfaced as SealedExchangeException so
    // callers drop the stale pin instead of keeping a dead host.
    expect(() => evil.listDir(''), throwsA(isA<SealedExchangeException>()));
    // The same stale pin must not survive on the transfer paths either:
    // a failed sealed upload/download re-checks the pin with a sealed root
    // listing and fails the same way — never a plaintext fallback.
    expect(
        () => evil.uploadFile(
            'x.txt', Uint8List.fromList(utf8.encode('x'))),
        throwsA(isA<SealedExchangeException>()));
    expect(() => evil.downloadFile('report.txt'),
        throwsA(isA<SealedExchangeException>()));
  });

  test('sealed listing of a missing folder is a plain error, not gone',
      () async {
    // The host answers 404 for the folder, but the sealed root listing
    // still succeeds: only the folder is gone. This must NOT be a
    // SealedExchangeException — the pin still works and the host stays.
    await expectLater(
        client.listDir('missing'),
        throwsA(predicate((e) =>
            e is HttpException && e is! SealedExchangeException &&
            e.message.contains('folder not found'))));
  });

  test('sealed download of a missing file is a plain error, not a drop',
      () async {
    // The host opened our envelope and answered a path-level 404: only the
    // file is missing, the pin still works — no exception that drops it.
    await expectLater(
        client.downloadFile('missing.txt'),
        throwsA(predicate((e) =>
            e is HttpException &&
            e is! SealedExchangeException &&
            e is! ServerGoneException &&
            e.message.contains('file not found'))));
  });

  test('sealed upload rejected over the size limit is a plain rejection',
      () async {
    final limited = LANdirServer(
      ServerConfig(
          port: 0,
          uploadDir: tmpDir,
          insecure: true,
          encrypted: true,
          maxUploadBytes: 8),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await limited.start();
    addTearDown(() => limited.stop());
    final c = LANdirClient('http://127.0.0.1:${limited.boundPort}/',
        hostKey: hostKey.publicKey);
    addTearDown(c.close);
    // 413 with a working pin: the follow-up root listing confirms the pin
    // is alive, so this is a plain rejection (false), not a drop-triggering
    // SealedExchangeException.
    final ok = await c.uploadFile(
        'big.txt', Uint8List.fromList(List.filled(64, 0x41)));
    expect(ok, isFalse);
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

  test('a sealed 200 whose payload is not OK does not count as uploaded',
      () async {
    // A path-rewriting MITM could answer an upload with any authenticated
    // 200 (e.g. by redirecting the request to another sealed endpoint whose
    // host happily returns a listing). The client must check the response
    // payload, not just status + authentication — the file would otherwise
    // be silently dropped while the UI shows success.
    final hijack = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => hijack.close(force: true));
    final hijackClient =
        LANdirClient('http://127.0.0.1:${hijack.port}/', hostKey: hostKey.publicKey);
    addTearDown(hijackClient.close);
    hijack.listen((req) async {
      final body = <int>[];
      await for (final chunk in req) {
        body.addAll(chunk);
      }
      // answer with a sealed root-listing payload instead of the sealed 'OK'
      final sealed = await sealResponse(
          Uint8List.fromList(utf8.encode('[]')),
          ephPublicKeyOf(Uint8List.fromList(body)),
          hostKey);
      req.response.statusCode = 200;
      req.response.headers.set('Content-Type', 'application/octet-stream');
      req.response.add(sealed);
      await req.response.close();
    });
    final ok = await hijackClient.uploadFile(
        'x.txt', Uint8List.fromList(utf8.encode('x')));
    expect(ok, isFalse);
  });
}
