// HTTP client for talking to a Landir server (desktop Python/Rust or
// another phone's host role). Pure Dart — no Flutter imports.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'multipart_writer.dart';

/// One entry from a server's /files listing.
class RemoteFile {
  final String name;
  final int size;
  final bool isDir;
  final double mtime;

  const RemoteFile({
    required this.name,
    required this.size,
    required this.isDir,
    required this.mtime,
  });

  factory RemoteFile.fromJson(Map<String, dynamic> json) => RemoteFile(
        name: json['name'] as String,
        size: (json['size'] as num).toInt(),
        isDir: json['is_dir'] as bool? ?? false,
        mtime: (json['mtime'] as num).toDouble(),
      );
}

/// A Landir server the client can talk to.
class LandirClient {
  final String baseUrl; // e.g. http://192.168.1.5:8000/abc123/
  final HttpClient _http = HttpClient();

  LandirClient(this.baseUrl) {
    // Normalize: ensure trailing slash
    if (!baseUrl.endsWith('/')) {
      throw ArgumentError('baseUrl must end with /');
    }
  }

  String get filesUrl => '${baseUrl}files';
  String get uploadUrl => '${baseUrl}upload';
  String downloadUrl(String relPath) =>
      '${baseUrl}fl/${relPath.split('/').map(Uri.encodeComponent).join('/')}';
  String listUrl(String relPath) =>
      '${baseUrl}ls/${relPath.split('/').map(Uri.encodeComponent).join('/')}';

  /// Fetch the root file listing. Returns entries newest-first.
  Future<List<RemoteFile>> listFiles() => listDir('');

  /// Fetch a directory listing. [relPath] is '' for root, or 'a/b' for
  /// nested directories.
  Future<List<RemoteFile>> listDir(String relPath) async {
    final url = relPath.isEmpty ? filesUrl : listUrl(relPath);
    final req = await _http.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('listDir failed: ${res.statusCode}');
    }
    final body = await res.transform(utf8.decoder).join();
    final list = jsonDecode(body) as List<dynamic>;
    return list
        .map((e) => RemoteFile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Upload a file via multipart POST. Returns true on success.
  Future<bool> uploadFile(String filename, Uint8List content) async {
    final (:body, :boundary) = buildMultipartBody(
      filename: filename,
      content: content,
    );
    final req = await _http.postUrl(Uri.parse(uploadUrl));
    req.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
    // Explicit Content-Length: the Python server reads exactly this many
    // bytes and rejects chunked uploads (no Content-Length -> reads 0).
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    await res.drain();
    return res.statusCode == 200;
  }

  /// Download a file. Returns the raw bytes.
  Future<Uint8List> downloadFile(String name) async {
    final req = await _http.getUrl(Uri.parse(downloadUrl(name)));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('download failed: ${res.statusCode}');
    }
    final chunks = <Uint8List>[];
    await for (final chunk in res) {
      chunks.add(Uint8List.fromList(chunk));
    }
    final total = chunks.fold<int>(0, (s, c) => s + c.length);
    final out = Uint8List(total);
    var offset = 0;
    for (final c in chunks) {
      out.setRange(offset, offset + c.length, c);
      offset += c.length;
    }
    return out;
  }

  void close() => _http.close(force: true);
}
