// Endpoint tests for server.dart — drives the real HTTP server on localhost.

import 'dart:convert';
import 'dart:io';

import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/core/server.dart';
import 'package:test/test.dart';

late String tmpDir;

/// Build a multipart body like a browser would.
List<int> multipartBody(String boundary, String filename, List<int> content) {
  final parts = <int>[];
  parts.addAll('--$boundary\r\n'.codeUnits);
  parts.addAll('Content-Disposition: form-data; name="file"; filename="$filename"\r\n\r\n'.codeUnits);
  parts.addAll(content);
  parts.addAll('\r\n--$boundary--\r\n'.codeUnits);
  return parts;
}

/// Sink whose exists() reflects names actually written through it,
/// independent of the server's uploadDir — mimics MediaStore on Android
/// where safeName's filesystem check can't see existing files.
class _SetBackedSink implements FileSink {
  final DirectoryFileSink inner;
  final Set<String> _written = {};
  _SetBackedSink(this.inner);

  @override
  Future<String> write(String name, Stream<List<int>> bytes) async {
    _written.add(name);
    return inner.write(name, bytes);
  }
  @override
  Future<File?> resolve(String name) => inner.resolve(name);
  @override
  Future<Stream<List<int>>?> openRead(String name) => inner.openRead(name);
  @override
  Future<int?> sizeOf(String name) => inner.sizeOf(name);
  @override
  Future<bool> exists(String name) async => _written.contains(name);
  @override
  Future<List<FileEntry>> list(String relPath) => inner.list(relPath);
}

void main() {
  late LandirServer server;
  late HttpClient client;
  late int port;

  setUpAll(() async {
    tmpDir = Directory.systemTemp.createTempSync('landir_server_test_').path;
  });

  tearDownAll(() async {
    client.close(force: true);
    await server.stop();
    Directory(tmpDir).deleteSync(recursive: true);
  });

  group('insecure mode endpoints', () {
    setUp(() async {
      final config = ServerConfig(
        port: 0, // ephemeral — we read back the bound port
        uploadDir: tmpDir,
        insecure: true,
      );
      server = LandirServer(config, DirectoryFileSink(tmpDir));
      await server.start();
      port = server.boundPort;
      client = HttpClient();
    });

    tearDown(() async {
      await server.stop();
    });

    Future<HttpClientResponse> get(String path) async {
      final req = await client.get('127.0.0.1', port, path);
      req.followRedirects = false;
      return req.close();
    }

    Future<HttpClientResponse> post(String path, List<int> body, String contentType) async {
      final req = await client.post('127.0.0.1', port, path);
      req.followRedirects = false;
      req.headers.set('Content-Type', contentType);
      req.add(body);
      return req.close();
    }

    test('GET / serves the HTML page', () async {
      final res = await get('/');
      expect(res.statusCode, 200);
      expect(res.headers.value('content-type'), contains('text/html'));
      final body = await res.transform(utf8.decoder).join();
      expect(body, contains('<title>Landir</title>'));
    });

    test('POST /upload saves a file, GET /files lists it, GET /fl/ downloads it', () async {
      final content = utf8.encode('hello landir');
      final body = multipartBody('TESTBND', 'hello.txt', content);
      final res = await post('/upload', body, 'multipart/form-data; boundary=TESTBND');
      expect(res.statusCode, 200);
      await res.drain();

      expect(File('$tmpDir/hello.txt').readAsBytesSync(), content);

      final listRes = await get('/files');
      expect(listRes.statusCode, 200);
      final listBody = await listRes.transform(utf8.decoder).join();
      final entries = jsonDecode(listBody) as List<dynamic>;
      expect(entries.any((e) => e['name'] == 'hello.txt'), isTrue);

      final dlRes = await get('/fl/hello.txt');
      expect(dlRes.statusCode, 200);
      expect(dlRes.headers.value('content-disposition'), contains('hello.txt'));
      final dlBody = await dlRes.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      expect(dlBody, content);
    });

    test('POST /upload with traversal filename lands inside uploads', () async {
      final body = multipartBody('BND', '../../pwn.txt', utf8.encode('evil'));
      final res = await post('/upload', body, 'multipart/form-data; boundary=BND');
      expect(res.statusCode, 200);
      await res.drain();
      // Must land inside tmpDir as "pwn.txt", not escape
      expect(File('$tmpDir/pwn.txt').existsSync(), isTrue);
      expect(File('$tmpDir/../../pwn.txt').existsSync(), isFalse);
    });

    test('GET /fl/ with traversal returns 404', () async {
      final res = await get('/fl/..%2F..%2Fetc%2Fpasswd');
      expect(res.statusCode, 404);
      await res.drain();
    });

    test('GET /fl/nonexistent returns 404', () async {
      final res = await get('/fl/nonexistent.txt');
      expect(res.statusCode, 404);
      await res.drain();
    });

    test('POST to wrong path returns 404', () async {
      final res = await post('/wrong', [1, 2, 3], 'text/plain');
      expect(res.statusCode, 404);
      await res.drain();
    });

    test('POST without boundary returns 400', () async {
      final res = await post('/upload', utf8.encode('data'), 'text/plain');
      expect(res.statusCode, 400);
      await res.drain();
    });

    test('GET /unknown returns 404', () async {
      final res = await get('/unknown');
      expect(res.statusCode, 404);
      await res.drain();
    });

    test('uploading the same filename twice does not overwrite — second gets timestamp suffix', () async {
      final body1 = multipartBody('C', 'dup.txt', utf8.encode('first'));
      await (await post('/upload', body1, 'multipart/form-data; boundary=C')).drain();
      final body2 = multipartBody('C', 'dup.txt', utf8.encode('second'));
      await (await post('/upload', body2, 'multipart/form-data; boundary=C')).drain();

      expect(File('$tmpDir/dup.txt').readAsStringSync(), 'first');
      final entries = Directory(tmpDir)
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split('/').last)
          .where((n) => n.startsWith('dup_'))
          .toList();
      expect(entries.length, 1, reason: 'expected one timestamp-suffixed dup file');
      expect(RegExp(r'^dup_\d{8}_\d{6}\.txt$').hasMatch(entries.first), isTrue);
      expect(File('$tmpDir/${entries.first}').readAsStringSync(), 'second');
    });

    test('sink-level collision renames as "stem (N).ext" preserving extension', () async {
      // uploadDir is empty so safeName never collides; the sink's own
      // exists() drives the sink-level path (as MediaStore does on Android).
      final emptyDir = Directory.systemTemp.createTempSync('landir_empty_').path;
      final storeDir = Directory.systemTemp.createTempSync('landir_store_').path;
      final forcingSink = _SetBackedSink(DirectoryFileSink(storeDir));
      final srv = LandirServer(
        ServerConfig(port: 0, uploadDir: emptyDir, insecure: true),
        forcingSink,
      );
      await srv.start();
      final p = srv.boundPort;
      final body = multipartBody('K', 'myphoto.jpg', utf8.encode('img'));
      Future<void> uploadOnce() async {
        final req = await client.post('127.0.0.1', p, '/upload');
        req.followRedirects = false;
        req.headers.set('Content-Type', 'multipart/form-data; boundary=K');
        req.add(body);
        await (await req.close()).drain();
      }
      await uploadOnce(); // writes myphoto.jpg
      await uploadOnce(); // collides -> myphoto (1).jpg
      final names = Directory(storeDir)
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split('/').last)
          .toList();
      expect(names, contains('myphoto.jpg'));
      expect(names, contains('myphoto (1).jpg'));
      expect(names.any((n) => n.contains('.jpg (')), isFalse,
          reason: 'extension must stay last');
      await srv.stop();
      Directory(emptyDir).deleteSync(recursive: true);
      Directory(storeDir).deleteSync(recursive: true);
    });

    // ---- M4 red-team battery ----

    /// Send a raw HTTP request over a socket. Returns the status code,
    /// or -1 if the server closed the connection without a response
    /// (Dart's HTTP stack rejects malformed Content-Length at the protocol
    /// layer before our handler runs — still a rejection, never a 200).
    Future<int> rawRequest(String raw) async {
      final socket = await Socket.connect('127.0.0.1', port);
      socket.write(raw);
      final buffer = StringBuffer();
      await for (final chunk in socket) {
        buffer.write(String.fromCharCodes(chunk));
      }
      await socket.close();
      final response = buffer.toString();
      if (response.isEmpty) return -1;
      return int.parse(response.split(' ')[1]);
    }

    test('POST with negative Content-Length is rejected (400 or closed)', () async {
      final status = await rawRequest(
          'POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=X\r\nContent-Length: -5\r\nConnection: close\r\n\r\n');
      expect(status == 400 || status == -1, isTrue,
          reason: 'expected 400 or connection-close, got $status');
    });

    test('POST with non-numeric Content-Length is rejected (400 or closed)', () async {
      final status = await rawRequest(
          'POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=X\r\nContent-Length: notanumber\r\nConnection: close\r\n\r\n');
      expect(status == 400 || status == -1, isTrue,
          reason: 'expected 400 or connection-close, got $status');
    });

    test('POST malformed multipart (no header separator) returns 400', () async {
      final body = '--X\r\nContent-Disposition: form-data; name="file"; filename="x.txt"\r\n--X--\r\n';
      final res = await post('/upload', utf8.encode(body),
          'multipart/form-data; boundary=X');
      expect(res.statusCode, 400);
      await res.drain();
    });

    test('POST multipart with CRLF-in-filename does not inject headers', () async {
      final body =
          '--X\r\nContent-Disposition: form-data; name="file"; filename="evil\r\nX-Bad: 1.txt"\r\n\r\ndata\r\n--X--\r\n';
      final res = await post('/upload', utf8.encode(body),
          'multipart/form-data; boundary=X');
      // Should either save a sanitized name or reject; must not crash
      expect(res.statusCode, 200);
      await res.drain();
      // The saved file must be inside tmpDir with a safe name — the CRLF
      // must have been stripped (no header injection possible).
      final saved = Directory(tmpDir).listSync().whereType<File>().toList();
      for (final f in saved) {
        final name = f.path.split('/').last;
        expect(name, isNot(contains('\r')));
        expect(name, isNot(contains('\n')));
      }
    });

    test('GET /fl/ with encoded traversal variants returns 404', () async {
      for (final path in [
        '/fl/%2e%2e%2f%2e%2e%2fetc%2fpasswd',
        '/fl/....%2f%2f....%2fetc%2fpasswd',
        '/fl/%252e%252e%252f double-encoded',
        '/fl/..%2f..%2f..%2froot%2fpasswd',
        '/fl/.%2e%2fsecret',
      ]) {
        final res = await get(path);
        expect(res.statusCode, 404, reason: 'path $path should be 404');
        await res.drain();
      }
    });

    test('GET /ls/ with traversal returns 404', () async {
      final res = await get('/ls/..%2f..%2fetc');
      expect(res.statusCode, 404);
      await res.drain();
    });

    test('upload size cap returns 413 when exceeded', () async {
      // Start a capped server on a new port
      final cappedDir = Directory.systemTemp.createTempSync('landir_cap_').path;
      final capped = LandirServer(
        ServerConfig(
          port: 0,
          uploadDir: cappedDir,
          insecure: true,
          maxUploadBytes: 10,
        ),
        DirectoryFileSink(cappedDir),
      );
      await capped.start();
      final cappedPort = capped.boundPort;
      final body = multipartBody('B', 'big.txt', List.filled(100, 65));
      final req = await client.post('127.0.0.1', cappedPort, '/upload');
      req.followRedirects = false;
      req.headers.set('Content-Type', 'multipart/form-data; boundary=B');
      req.contentLength = body.length; // explicit CL so the cap can trigger
      req.add(body);
      final res = await req.close();
      expect(res.statusCode, 413);
      await res.drain();
      await capped.stop();
      Directory(cappedDir).deleteSync(recursive: true);
    });
  });

  group('secret mode endpoints', () {
    setUp(() async {
      final config = ServerConfig(
        port: 0,
        uploadDir: tmpDir,
        insecure: false,
        secretToken: 'testtoken123',
      );
      server = LandirServer(config, DirectoryFileSink(tmpDir));
      await server.start();
      port = server.boundPort;
      client = HttpClient();
    });

    tearDown(() async {
      await server.stop();
    });

    Future<HttpClientResponse> get(String path) async {
      final req = await client.get('127.0.0.1', port, path);
      req.followRedirects = false;
      return req.close();
    }

    Future<HttpClientResponse> post(String path, List<int> body, String contentType) async {
      final req = await client.post('127.0.0.1', port, path);
      req.followRedirects = false;
      req.headers.set('Content-Type', contentType);
      req.add(body);
      return req.close();
    }

    test('GET /testtoken123 redirects to /testtoken123/', () async {
      final res = await get('/testtoken123');
      expect(res.statusCode, 302);
      expect(res.headers.value('location'), '/testtoken123/');
      await res.drain();
    });

    test('GET /testtoken123/ serves the page', () async {
      final res = await get('/testtoken123/');
      expect(res.statusCode, 200);
      final body = await res.transform(utf8.decoder).join();
      expect(body, contains('<title>Landir</title>'));
    });

    test('GET / (no token) returns 404 in secret mode', () async {
      final res = await get('/');
      expect(res.statusCode, 404);
      await res.drain();
    });

    test('POST /testtoken123/upload works, POST /upload is 404', () async {
      final body = multipartBody('SB', 'secret.txt', utf8.encode('s3cret'));
      final res = await post('/testtoken123/upload', body, 'multipart/form-data; boundary=SB');
      expect(res.statusCode, 200);
      await res.drain();
      expect(File('$tmpDir/secret.txt').existsSync(), isTrue);

      final res2 = await post('/upload', body, 'multipart/form-data; boundary=SB');
      expect(res2.statusCode, 404);
      await res2.drain();
    });

    test('GET /testtoken123/files returns JSON listing', () async {
      final res = await get('/testtoken123/files');
      expect(res.statusCode, 200);
      expect(res.headers.value('content-type'), contains('application/json'));
      await res.drain();
    });
  });
}
