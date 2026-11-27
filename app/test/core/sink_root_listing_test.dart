// Regression tests for folder navigation on app hosts where the FileSink
// root is NOT the server's uploadDir (Android: MediaStore, iOS/desktop:
// Documents dir) — the real configuration in server_provider.dart.
//
// Bug: _listingJsonBytesForPath checked Directory(uploadDir/sub) on the
// local filesystem, so every subfolder listing 404'd on app hosts (the
// client then treated the 404 as "server gone" and deleted the host).
// Existence must come from the sink (FileSink.isDir).

import 'dart:io';

import 'package:landir_app/src/core/client.dart';
import 'package:landir_app/src/core/crypto.dart';
import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/core/server.dart';
import 'package:test/test.dart';

void main() {
  late String uploadDir;
  late String sinkRoot;
  late HostKey hostKey;
  late LANdirServer server;
  late String baseUrl;

  setUpAll(() async {
    uploadDir = Directory.systemTemp.createTempSync('landir_up_').path;
    sinkRoot = Directory.systemTemp.createTempSync('landir_sink_').path;
    final keyDir = Directory.systemTemp.createTempSync('landir_key_');
    addTearDown(() {
      Directory(uploadDir).deleteSync(recursive: true);
      Directory(sinkRoot).deleteSync(recursive: true);
      keyDir.deleteSync(recursive: true);
    });
    // What actually happens on a desktop app host: files live in the sink
    // root (Documents), uploadDir (app-support/uploads) stays empty.
    Directory('$sinkRoot/sub').createSync();
    File('$sinkRoot/sub/inner.txt').writeAsStringSync('inner');
    File('$sinkRoot/top.txt').writeAsStringSync('top');
    // A folder with a space (whitelisted): reachable in both modes. The
    // sealed envelope carries paths verbatim, so "my folder" must not be
    // percent-decoded (a decode would be a no-op here, but a name like
    // "100%20off" must be rejected, not mangled into "100 off").
    Directory('$sinkRoot/my folder').createSync();
    File('$sinkRoot/my folder/x.txt').writeAsStringSync('x');

    hostKey = await HostKeyStore(keyDir.path).loadOrCreate();
    // Encrypted mode: key-only host, fixed root paths, no token — exactly
    // what a PC (Linux app) host serves by default.
    server = LANdirServer(
      ServerConfig(
          port: 0, uploadDir: uploadDir, insecure: true, encrypted: true),
      DirectoryFileSink(sinkRoot), // sink root != uploadDir, on purpose
      hostKey: hostKey,
    );
    await server.start();
    baseUrl = 'http://127.0.0.1:${server.boundPort}/';
  });

  tearDownAll(() async {
    await server.stop();
  });

  test('sealed: root listing shows the folder (sink-based)', () async {
    final client = LANdirClient(baseUrl, hostKey: hostKey.publicKey);
    addTearDown(() => client.close());
    final root = await client.listDir('');
    expect(root.any((f) => f.name == 'sub' && f.isDir), isTrue);
    expect(root.any((f) => f.name == 'top.txt' && !f.isDir), isTrue);
  });

  test('sealed: navigating into the folder works despite uploadDir mismatch',
      () async {
    final client = LANdirClient(baseUrl, hostKey: hostKey.publicKey);
    addTearDown(() => client.close());
    // This was the reported bug: 404 -> ServerGoneException -> host deleted.
    final entries = await client.listDir('sub');
    expect(entries.any((f) => f.name == 'inner.txt'), isTrue);
  });

  test('sealed: folder name with a space navigates verbatim', () async {
    final client = LANdirClient(baseUrl, hostKey: hostKey.publicKey);
    addTearDown(() => client.close());
    final entries = await client.listDir('my folder');
    expect(entries.any((f) => f.name == 'x.txt'), isTrue);
  });

  test('sealed: percent-escape folder name is rejected, not mangled',
      () async {
    final client = LANdirClient(baseUrl, hostKey: hostKey.publicKey);
    addTearDown(() => client.close());
    // '%' is outside the whitelist in every implementation; the sealed path
    // must not decode "100%20off" into "100 off" and list the wrong folder.
    try {
      await client.listDir('100%20off');
      fail('expected an HttpException');
    } on ServerGoneException {
      fail('must not look like a gone server');
    } on HttpException catch (e) {
      expect(e.message, contains('404'));
    }
  });

  test('sealed: missing subfolder is a plain 404, NOT server-gone', () async {
    final client = LANdirClient(baseUrl, hostKey: hostKey.publicKey);
    addTearDown(() => client.close());
    try {
      await client.listDir('does-not-exist');
      fail('expected an HttpException');
    } on ServerGoneException {
      fail('a missing subfolder must not look like a gone server');
    } on HttpException catch (e) {
      expect(e.message, contains('404'));
    }
  });

  test('plaintext: ls/ of a subfolder works despite uploadDir mismatch',
      () async {
    final plain = LANdirServer(
      ServerConfig(
          port: 0, uploadDir: uploadDir, insecure: true, encrypted: false),
      DirectoryFileSink(sinkRoot),
    );
    await plain.start();
    addTearDown(() => plain.stop());
    final client =
        LANdirClient('http://127.0.0.1:${plain.boundPort}/');
    addTearDown(() => client.close());
    final entries = await client.listDir('sub');
    expect(entries.any((f) => f.name == 'inner.txt'), isTrue);
  });

  test('plaintext: missing subfolder is a plain 404, NOT server-gone',
      () async {
    final plain = LANdirServer(
      ServerConfig(
          port: 0, uploadDir: uploadDir, insecure: true, encrypted: false),
      DirectoryFileSink(sinkRoot),
    );
    await plain.start();
    addTearDown(() => plain.stop());
    final client = LANdirClient('http://127.0.0.1:${plain.boundPort}/');
    addTearDown(() => client.close());
    try {
      await client.listDir('nope');
      fail('expected an HttpException');
    } on ServerGoneException {
      fail('a missing subfolder must not look like a gone server');
    } on HttpException catch (e) {
      expect(e.message, contains('404'));
    }
  });

  test('root listing 404 still raises ServerGoneException', () async {
    // Keyless client against the encrypted host: every plaintext route is a
    // blind 404, so the ROOT listing reports the server as gone.
    final client = LANdirClient(baseUrl);
    addTearDown(() => client.close());
    expect(() => client.listDir(''), throwsA(isA<ServerGoneException>()));
  });
}
