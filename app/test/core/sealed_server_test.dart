// M2 tests: sealed endpoints on the Dart host (docs/design/001). Drives the
// real HTTP server on localhost with a host key, seals client requests with
// the crypto module, and checks decrypt-then-delegate behavior plus the
// SPEC.md rules holding below the crypto layer.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:landir_app/src/core/crypto.dart';
import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/core/server.dart';
import 'package:test/test.dart';

late String tmpDir;
late HostKey hostKey;

List<int> multipartBody(String boundary, String filename, List<int> content) {
  final parts = <int>[];
  parts.addAll('--$boundary\r\n'.codeUnits);
  parts.addAll(
      'Content-Disposition: form-data; name="file"; filename="$filename"\r\n\r\n'
          .codeUnits);
  parts.addAll(content);
  parts.addAll('\r\n--$boundary--\r\n'.codeUnits);
  return parts;
}

/// POSTs a sealed request and returns (status, responseEnvelope-or-body).
Future<(int, Uint8List)> sealedPost(
    HttpClient client, String url, Uint8List plaintext) async {
  final req = await client.postUrl(Uri.parse(url));
  final sealed = await sealToHost(plaintext, hostKey.publicKey);
  req.headers.set('Content-Type', 'application/octet-stream');
  req.contentLength = sealed.envelope.length;
  req.add(sealed.envelope);
  final res = await req.close();
  final chunks = <Uint8List>[];
  await for (final c in res) {
    chunks.add(Uint8List.fromList(c));
  }
  final total = chunks.fold<int>(0, (s, c) => s + c.length);
  final body = Uint8List(total);
  var o = 0;
  for (final c in chunks) {
    body.setRange(o, o + c.length, c);
    o += c.length;
  }
  if (res.statusCode != 200) return (res.statusCode, body);
  final opened = await openResponse(body, sealed.ephKeyPair, hostKey.publicKey);
  return (res.statusCode, opened ?? Uint8List(0));
}

void main() {
  late LANdirServer server;
  late HttpClient client;
  late String base;

  setUpAll(() async {
    tmpDir = Directory.systemTemp.createTempSync('landir_sealed_test_').path;
    final keyDir = Directory.systemTemp.createTempSync('landir_sealed_key_');
    addTearDown(() => keyDir.deleteSync(recursive: true));
    hostKey = await HostKeyStore(keyDir.path).loadOrCreate();
    // Disentangled semantics (ADR 0003): an encrypted host is key-only —
    // fixed root paths, no token anywhere.
    server = LANdirServer(
      ServerConfig(
          port: 0, uploadDir: tmpDir, insecure: true, encrypted: true),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await server.start();
    client = HttpClient();
    base = 'http://127.0.0.1:${server.boundPort}/';
  });

  tearDownAll(() async {
    client.close(force: true);
    await server.stop();
    Directory(tmpDir).deleteSync(recursive: true);
  });

  test('sealed upload lands in the uploads dir and lists sealed', () async {
    const boundary = 'sealedboundary';
    final inner = <int>[
      ...utf8.encode('$boundary\r\n'),
      ...multipartBody(boundary, 'hello.txt', utf8.encode('sealed hello')),
    ];
    final (status, resp) = await sealedPost(client, '${base}supload',
        Uint8List.fromList(inner));
    expect(status, 200);
    expect(utf8.decode(resp), 'OK');
    expect(File('$tmpDir/hello.txt').readAsStringSync(), 'sealed hello');

    final (lsStatus, listing) = await sealedPost(
        client, '${base}sfiles', Uint8List(0));
    expect(lsStatus, 200);
    final entries = jsonDecode(utf8.decode(listing)) as List<dynamic>;
    expect(entries.any((e) => e['name'] == 'hello.txt'), isTrue);
  });

  test('sealed download returns the file bytes', () async {
    final (status, bytes) =
        await sealedPost(client, '${base}sfl', utf8.encode('hello.txt'));
    expect(status, 200);
    expect(utf8.decode(bytes), 'sealed hello');
  });

  test('sealed ls of a subdirectory works', () async {
    Directory('$tmpDir/sub').createSync();
    File('$tmpDir/sub/inner.txt').writeAsStringSync('inner');
    final (status, listing) =
        await sealedPost(client, '${base}sls', utf8.encode('sub'));
    expect(status, 200);
    final entries = jsonDecode(utf8.decode(listing)) as List<dynamic>;
    expect(entries.any((e) => e['name'] == 'inner.txt'), isTrue);
  });

  test('AEAD failure on the envelope -> 400', () async {
    final sealed = await sealToHost(utf8.encode('x'), hostKey.publicKey);
    sealed.envelope[sealed.envelope.length - 2] ^= 0x40;
    final req = await client.postUrl(Uri.parse('${base}sfiles'));
    req.contentLength = sealed.envelope.length;
    req.add(sealed.envelope);
    final res = await req.close();
    await res.drain();
    expect(res.statusCode, 400);
  });

  test('traversal inside a sealed upload body still lands inside uploads (SPEC rule 1)',
      () async {
    const boundary = 'travboundary';
    final inner = <int>[
      ...utf8.encode('$boundary\r\n'),
      ...multipartBody(boundary, '../../evil.txt', utf8.encode('evil')),
    ];
    final (status, _) =
        await sealedPost(client, '${base}supload', Uint8List.fromList(inner));
    expect(status, 200);
    // safeName reduces to the basename: lands inside tmpDir, never escapes.
    expect(File('$tmpDir/evil.txt').existsSync(), isTrue);
    expect(File('$tmpDir/../evil.txt').existsSync(), isFalse);
  });

  test('sealed sfl path traversal -> 404', () async {
    final (status, _) =
        await sealedPost(client, '${base}sfl', utf8.encode('../../etc/passwd'));
    expect(status, 404);
  });

  test('encrypted host: NOTHING plaintext is readable or writable', () async {
    // A browser (or an unpaired attacker who learns the URL) must see the
    // same blind 404 everywhere — page, listing, download, and upload.
    final paths = <(String, String)>[
      ('GET', '/'),
      ('GET', '/files'),
      ('GET', '/ls/'),
      ('GET', '/fl/hello.txt'),
      ('POST', '/upload',),
    ];
    for (final (method, path) in paths) {
      final url = Uri.parse('http://127.0.0.1:${server.boundPort}$path');
      final HttpClientRequest req;
      if (method == 'GET') {
        req = await client.getUrl(url);
      } else {
        req = await client.postUrl(url);
        req.headers.set(
            'Content-Type', 'multipart/form-data; boundary=x');
        req.add(List.filled(10, 0x61));
      }
      final res = await req.close();
      await res.drain();
      expect(res.statusCode, 404, reason: '$method $path must be blind');
    }
  });

  test('hostKey without the mode on behaves keyless on the wire', () async {
    final keyIgnored = LANdirServer(
      ServerConfig(
          port: 0, uploadDir: tmpDir, insecure: false, secretToken: 'kk'),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await keyIgnored.start();
    try {
      // Plain access works...
      final res = await client.getUrl(
          Uri.parse('http://127.0.0.1:${keyIgnored.boundPort}/kk/files'));
      final r2 = await res.close();
      expect(r2.statusCode, 200);
      await r2.drain();
      // ...and the sealed endpoints stay closed (no mode, no key on the wire).
      final req = await client.postUrl(
          Uri.parse('http://127.0.0.1:${keyIgnored.boundPort}/kk/sfiles'));
      final sealed = await sealToHost(Uint8List(0), hostKey.publicKey);
      req.contentLength = sealed.envelope.length;
      req.add(sealed.envelope);
      final r3 = await req.close();
      await r3.drain();
      expect(r3.statusCode, 404);
    } finally {
      await keyIgnored.stop();
    }
  });

  test('keyless host answers 404 on sealed endpoints', () async {
    final keyless = LANdirServer(
      ServerConfig(
          port: 0, uploadDir: tmpDir, insecure: false, secretToken: 'nope'),
      DirectoryFileSink(tmpDir),
    );
    await keyless.start();
    try {
      final req = await client
          .postUrl(Uri.parse('http://127.0.0.1:${keyless.boundPort}/nope/sfiles'));
      final sealed = await sealToHost(Uint8List(0), hostKey.publicKey);
      req.contentLength = sealed.envelope.length;
      req.add(sealed.envelope);
      final res = await req.close();
      await res.drain();
      expect(res.statusCode, 404);
    } finally {
      await keyless.stop();
    }
  });

  test('maxUploadBytes applies to the decrypted payload -> 413', () async {
    final limited = LANdirServer(
      ServerConfig(
          port: 0,
          uploadDir: tmpDir,
          insecure: true,
          maxUploadBytes: 16,
          encrypted: true),
      DirectoryFileSink(tmpDir),
      hostKey: hostKey,
    );
    await limited.start();
    try {
      const boundary = 'bigboundary';
      final inner = <int>[
        ...utf8.encode('$boundary\r\n'),
        ...multipartBody(boundary, 'big.bin', List.filled(64, 7)),
      ];
      final sealed = await sealToHost(
          Uint8List.fromList(inner), hostKey.publicKey);
      final req = await client
          .postUrl(Uri.parse('http://127.0.0.1:${limited.boundPort}/supload'));
      req.contentLength = sealed.envelope.length;
      req.add(sealed.envelope);
      final res = await req.close();
      await res.drain();
      expect(res.statusCode, 413);
    } finally {
      await limited.stop();
    }
  });

  test('cross-endpoint envelope splices are rejected (the path has no AAD)',
      () async {
    // The request path is not authenticated: a path-rewriting MITM can post
    // a valid sealed envelope to a different sealed endpoint. Every splice
    // must fail with a visible 4xx — a 200 would make the client believe a
    // dropped upload succeeded (or save a listing as the downloaded file).
    // The plaintext shapes are mutually incompatible, and sfiles enforces
    // its documented empty plaintext, so nothing answers 200 for a
    // redirected envelope.
    Directory('$tmpDir/splicedir').createSync();
    File('$tmpDir/splice-notes.txt').writeAsStringSync('my notes');

    Future<(int, Uint8List)> postEnvelope(
        String url, Uint8List envelope) async {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.set('Content-Type', 'application/octet-stream');
      req.contentLength = envelope.length;
      req.add(envelope);
      final res = await req.close();
      final chunks = <int>[];
      await for (final c in res) {
        chunks.addAll(c);
      }
      return (res.statusCode, Uint8List.fromList(chunks));
    }

    const boundary = 'testboundary42';
    final uploadPlain = Uint8List.fromList(utf8.encode('$boundary\r\n') +
        multipartBody(boundary, 'splice-report.pdf', utf8.encode('x')));
    final cases = <(String, String, Uint8List)>[
      ('upload', '${base}supload', uploadPlain),
      ('root-listing', '${base}sfiles', Uint8List(0)),
      ('sub-listing', '${base}sls',
          Uint8List.fromList(utf8.encode('splicedir'))),
      ('download', '${base}sfl',
          Uint8List.fromList(utf8.encode('splice-notes.txt'))),
    ];
    final targets = cases.map((c) => c.$2).toList();
    for (final (name, intended, plain) in cases) {
      final sealed = await sealToHost(plain, hostKey.publicKey);
      for (final target in targets) {
        final (status, _) = await postEnvelope(target, sealed.envelope);
        if (target == intended) {
          expect(status, 200, reason: '$name -> $target');
        } else {
          expect(status, anyOf(400, 404),
              reason: '$name redirected to $target answered $status');
        }
      }
    }
  });
}
