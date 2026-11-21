// Tests for the M3 client core: LANdirClient against a live LANdirServer
// (which is behavior-identical to the Python reference).

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:landir_app/src/core/client.dart';
import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/core/multipart_writer.dart';
import 'package:landir_app/src/core/server.dart';
import 'package:test/test.dart';

void main() {
  late String tmpDir;
  late LANdirServer server;
  late int port;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('landir_m3_').path;
    final config = ServerConfig(
      port: 0,
      uploadDir: tmpDir,
      insecure: true,
    );
    server = LANdirServer(config, DirectoryFileSink(tmpDir));
    await server.start();
    port = server.boundPort;
  });

  tearDown(() async {
    await server.stop();
    Directory(tmpDir).deleteSync(recursive: true);
  });

  test('listFiles returns empty list on fresh server', () async {
    final client = LANdirClient('http://127.0.0.1:$port/');
    final files = await client.listFiles();
    expect(files, isEmpty);
    client.close();
  });

  test('uploadFile then listFiles then downloadFile round-trip', () async {
    final client = LANdirClient('http://127.0.0.1:$port/');
    final content = Uint8List.fromList(utf8.encode('hello from client'));

    final ok = await client.uploadFile('greeting.txt', content);
    expect(ok, isTrue);

    final files = await client.listFiles();
    expect(files.length, 1);
    expect(files.first.name, 'greeting.txt');
    expect(files.first.size, content.length);

    final downloaded = await client.downloadFile('greeting.txt');
    expect(downloaded, content);
    client.close();
  });

  test('uploadFile with binary content preserves bytes exactly', () async {
    final client = LANdirClient('http://127.0.0.1:$port/');
    // Include CRLF, null bytes, and high bytes to stress the multipart framing
    final content = Uint8List.fromList([
      0x00, 0x0d, 0x0a, 0xff, 0xfe, 0x0d, 0x0a, 0x0d, 0x0a, 0x80, 0x7f, 0x41,
    ]);
    final ok = await client.uploadFile('binary.dat', content);
    expect(ok, isTrue);

    final downloaded = await client.downloadFile('binary.dat');
    expect(downloaded, content);
    client.close();
  });

  test('buildMultipartBody produces a parseable body', () {
    final content = Uint8List.fromList(utf8.encode('test content'));
    final (:body, :boundary) = buildMultipartBody(
      filename: 'test.txt',
      content: content,
    );
    final bodyStr = latin1.decode(body);
    expect(bodyStr, contains('--$boundary'));
    expect(bodyStr, contains('filename="test.txt"'));
    expect(bodyStr, contains('test content'));
    expect(bodyStr, endsWith('--$boundary--\r\n'));
  });

  test('downloadFile on nonexistent file throws', () async {
    final client = LANdirClient('http://127.0.0.1:$port/');
    // Await each assertion: the fire-and-forget form raced with close()
    // and asserted on an aborted connection, not the actual 404.
    await expectLater(
        client.downloadFile('nope.txt'), throwsA(isA<HttpException>()));
    await expectLater(client.downloadFile('nope.txt'),
        throwsA(isNot(isA<ServerGoneException>())));
    client.close();
  });

  test('listDir on a stale token path throws ServerGoneException', () async {
    // Secret-mode server: any path under the wrong token is a 404, which is
    // what a client sees when the server restarted with a new token.
    final secretDir = Directory.systemTemp.createTempSync('landir_secret_');
    final secret = LANdirServer(
      ServerConfig(
        port: 0,
        uploadDir: secretDir.path,
        secretToken: 'freshtoken',
      ),
      DirectoryFileSink(secretDir.path),
    );
    await secret.start();
    addTearDown(() async {
      await secret.stop();
      secretDir.deleteSync(recursive: true);
    });

    final stale = LANdirClient('http://127.0.0.1:${secret.boundPort}/oldtoken/');
    await expectLater(
        stale.listDir(''), throwsA(isA<ServerGoneException>()));
    stale.close();
  });

  test('uploadFile to a stale token path returns false, not server-gone',
      () async {
    // A stale upload endpoint also 404s, but uploads report failure via
    // their bool return; they must never raise ServerGoneException.
    final secretDir = Directory.systemTemp.createTempSync('landir_secret_');
    final secret = LANdirServer(
      ServerConfig(
        port: 0,
        uploadDir: secretDir.path,
        secretToken: 'freshtoken',
      ),
      DirectoryFileSink(secretDir.path),
    );
    await secret.start();
    addTearDown(() async {
      await secret.stop();
      secretDir.deleteSync(recursive: true);
    });

    final stale = LANdirClient('http://127.0.0.1:${secret.boundPort}/oldtoken/');
    final ok = await stale.uploadFile('x.txt', Uint8List.fromList([1]));
    expect(ok, isFalse);
    stale.close();
  });

  test('a 404 on download is a plain HttpException, not server-gone', () async {
    // A missing file is a 404 too, but it must not be mistaken for a dead
    // server: only listing requests raise ServerGoneException.
    final client = LANdirClient('http://127.0.0.1:$port/');
    await expectLater(
      () => client.downloadFile('missing.txt'),
      throwsA(isA<HttpException>()),
    );
    await expectLater(
      () => client.downloadFile('missing.txt'),
      throwsA(isNot(isA<ServerGoneException>())),
    );
    client.close();
  });

  test('listDir navigates subdirectories', () async {
    // Create a subdirectory with a file inside the server's upload dir
    final subDir = Directory('$tmpDir/reports');
    subDir.createSync();
    File('${subDir.path}/q3.txt').writeAsStringSync('quarterly');

    final client = LANdirClient('http://127.0.0.1:$port/');

    // Root listing shows the directory
    final root = await client.listDir('');
    expect(root.any((f) => f.name == 'reports' && f.isDir), isTrue);

    // Listing the subdirectory shows the file inside
    final sub = await client.listDir('reports');
    expect(sub.length, 1);
    expect(sub.first.name, 'q3.txt');
    expect(sub.first.isDir, isFalse);

    // Nested path encoding works
    expect(client.listUrl('my folder/a b'), contains('my%20folder/a%20b'));

    // Nonexistent dir throws
    expect(() => client.listDir('nope'), throwsA(isA<HttpException>()));

    // Downloading a file inside a subdirectory uses the full rel path
    final dl = await client.downloadFile('reports/q3.txt');
    expect(utf8.decode(dl), 'quarterly');
    client.close();
  });

  test('upload sends explicit Content-Length (Python server requires it)', () async {
    // Raw socket server that records request headers, then replies 200 OK.
    final serverSocket = await ServerSocket.bind('127.0.0.1', 0);
    final port = serverSocket.port;
    final requestFuture = serverSocket.first.then((socket) async {
      final chunks = <List<int>>[];
      final done = Completer<void>();
      socket.listen(chunks.add, onDone: done.complete);
      // Wait until the full header block has arrived, then reply.
      while (!done.isCompleted) {
        await Future.delayed(const Duration(milliseconds: 10));
        final all = chunks.expand((c) => c).toList();
        if (String.fromCharCodes(all).contains('\r\n\r\n')) break;
      }
      socket.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK'));
      await socket.close();
      await done.future;
      return String.fromCharCodes(chunks.expand((c) => c).toList());
    });

    final client = LANdirClient('http://127.0.0.1:$port/');
    final ok = await client.uploadFile('hdr.txt', Uint8List.fromList(utf8.encode('x')));
    expect(ok, isTrue);
    client.close();

    final headers = await requestFuture;
    final lower = headers.toLowerCase();
    expect(lower, contains('content-length:'),
        reason: 'must send Content-Length, not chunked — Python reads it');
    expect(lower, isNot(contains('transfer-encoding: chunked')));
    await serverSocket.close();
  });

  test('client works in secret mode under token path', () async {
    // Start a second server in secret mode
    final tmpDir2 = Directory.systemTemp.createTempSync('landir_m3_sec_').path;
    final config = ServerConfig(
      port: 0,
      uploadDir: tmpDir2,
      insecure: false,
      secretToken: 'abc123',
    );
    final server2 = LANdirServer(config, DirectoryFileSink(tmpDir2));
    await server2.start();
    final port2 = server2.boundPort;

    final client = LANdirClient('http://127.0.0.1:$port2/abc123/');
    final ok = await client.uploadFile('secret.txt',
        Uint8List.fromList(utf8.encode('secret data')));
    expect(ok, isTrue);
    final files = await client.listFiles();
    expect(files.first.name, 'secret.txt');
    client.close();
    await server2.stop();
    Directory(tmpDir2).deleteSync(recursive: true);
  });
}
