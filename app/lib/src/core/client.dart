// HTTP client for talking to a LANdir server (desktop Python/Rust or
// another phone's host role). Pure Dart — no Flutter imports.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crypto.dart';
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

/// A directory listing answered 404: the base URL (host:port + token path)
/// no longer maps to a LANdir server. Callers treat this as "server is gone".
///
/// Only listing requests raise this. A 404 on a download just means the file
/// is missing and stays a plain [HttpException].
class ServerGoneException extends HttpException {
  final String url;

  ServerGoneException(this.url) : super('server gone (404): $url');
}

/// A sealed listing exchange failed: the host answered, but not with an
/// authenticated 200 — it rejected our envelope (the host re-keyed or the
/// pin is stale) or the response did not open under the pinned key
/// (tampering). A pinned host is always sealed with never a fallback, so
/// this can never succeed later: callers treat it like [ServerGoneException]
/// and drop the host. Only raised for the pinned-key listing path; a missing
/// subfolder on a live host stays a plain [HttpException].
class SealedExchangeException extends HttpException {
  final String url;
  final int status;

  SealedExchangeException(this.url, this.status)
      : super('sealed exchange failed ($status): $url');
}

/// A LANdir server the client can talk to.
class LANdirClient {
  final String baseUrl; // e.g. http://192.168.1.5:8000/abc123/

  /// The pinned host key (design 001, M3/M4). When set, every request goes
  /// to the sealed endpoints and every response must open under the pinned
  /// key — a pinned server is always sealed, never a silent fallback.
  /// Null means keyless plaintext mode (host QR carried no #k=).
  final Uint8List? hostKey;

  final HttpClient _http = HttpClient();

  LANdirClient(this.baseUrl, {this.hostKey}) {
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

  // Sealed endpoint mirrors (all POST, envelope in/out).
  String get _sfilesUrl => '${baseUrl}sfiles';
  String get _suploadUrl => '${baseUrl}supload';
  String get _slsUrl => '${baseUrl}sls';
  String get _sflUrl => '${baseUrl}sfl';

  /// Fetch the root file listing. Returns entries newest-first.
  Future<List<RemoteFile>> listFiles() => listDir('');

  /// POSTs [plaintext] as a sealed envelope to [url] and opens the sealed
  /// response. Returns (status, plaintext); the plaintext is null when the
  /// response does not authenticate under the pinned key (tamper/MITM) —
  /// callers turn that into an error, never into a plaintext fallback.
  Future<(int, Uint8List?)> _sealedPost(String url, Uint8List plaintext) async {
    final key = hostKey;
    if (key == null) throw StateError('sealed call on a keyless client');
    final sealed = await sealToHost(plaintext, key);
    final req = await _http.postUrl(Uri.parse(url));
    req.headers.set('Content-Type', 'application/octet-stream');
    req.contentLength = sealed.envelope.length;
    req.add(sealed.envelope);
    final res = await req.close();
    final body = await _readAll(res);
    return (res.statusCode, await openResponse(body, sealed.ephKeyPair, key));
  }

  /// Fetch a directory listing. [relPath] is '' for root, or 'a/b' for
  /// nested directories.
  Future<List<RemoteFile>> listDir(String relPath) async {
    if (hostKey != null) return _listDirSealed(relPath);
    final url = relPath.isEmpty ? filesUrl : listUrl(relPath);
    final req = await _http.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode == 404) {
      await res.drain();
      throw await _goneOrMissing(relPath, url);
    }
    if (res.statusCode != 200) {
      throw HttpException('listDir failed: ${res.statusCode}');
    }
    final body = await res.transform(utf8.decoder).join();
    return _parseListing(body, url);
  }

  /// A 404 on the ROOT listing means the base URL no longer maps to a
  /// LANdir server -> [ServerGoneException]. A 404 on a SUBDIRECTORY listing
  /// only means that folder is gone/rejected — but the root is re-checked
  /// first, so a restarted server (new token, same address) is still
  /// detected as gone rather than silently kept.
  Future<HttpException> _goneOrMissing(String relPath, String url) async {
    if (relPath.isEmpty) return ServerGoneException(url);
    final rootReq = await _http.getUrl(Uri.parse(filesUrl));
    final rootRes = await rootReq.close();
    final gone = rootRes.statusCode == 404;
    await rootRes.drain();
    return gone
        ? ServerGoneException(filesUrl)
        : HttpException('folder not found (404): $url');
  }

  Future<List<RemoteFile>> _listDirSealed(String relPath) async {
    final url = relPath.isEmpty ? _sfilesUrl : _slsUrl;
    final plaintext =
        relPath.isEmpty ? Uint8List(0) : Uint8List.fromList(utf8.encode(relPath));
    final result = await _sealedPost(url, plaintext);
    final (status, opened) = result;
    if (status == 404) {
      if (relPath.isEmpty) throw ServerGoneException(url);
      // Subfolder 404: the server answered, so it exists — confirm with a
      // sealed root listing before deciding the pin is stale (it can't be:
      // the key is pinned, so a 200 root just means "folder missing").
      final root = await _sealedPost(_sfilesUrl, Uint8List(0));
      if (root.$1 == 404) throw ServerGoneException(_sfilesUrl);
      throw HttpException('sealed listDir failed: folder not found (404)');
    }
    if (status != 200 || opened == null) {
      throw SealedExchangeException(url, status);
    }
    return _parseListing(utf8.decode(opened), url);
  }

  /// After an ambiguous sealed failure on upload/download, re-check whether
  /// the pinned key can still talk to this host at all, with a sealed ROOT
  /// listing (the same confirmation [listDir] uses for a subfolder 404):
  ///
  /// - root listing completes -> the pin works; the earlier failure was
  ///   about the transfer itself, so return normally and the caller keeps
  ///   the host;
  /// - root 404 -> the sealed endpoints are gone (host left encryption
  ///   mode, or the address no longer maps to it): [ServerGoneException];
  /// - root fails the same way -> the pin is stale (host re-keyed):
  ///   [SealedExchangeException]. Both drop the host in the provider.
  ///
  /// A connection error here propagates as a plain transport error, so a
  /// host that simply died stays registered (transient).
  Future<void> _confirmPinUsable() async {
    final (status, opened) = await _sealedPost(_sfilesUrl, Uint8List(0));
    if (status == 200 && opened != null) return;
    if (status == 404) throw ServerGoneException(_sfilesUrl);
    throw SealedExchangeException(_sfilesUrl, status);
  }

  List<RemoteFile> _parseListing(String body, String url) {
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
    if (hostKey != null) return _uploadFileSealed(body, boundary);
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

  Future<bool> _uploadFileSealed(List<int> body, String boundary) async {
    // The sealed upload plaintext is: boundary '\r\n' + multipart body.
    final inner = Uint8List(boundary.length + 2 + body.length);
    inner.setRange(0, boundary.length, utf8.encode(boundary));
    inner[boundary.length] = 0x0d;
    inner[boundary.length + 1] = 0x0a;
    inner.setRange(boundary.length + 2, inner.length, body);
    final (status, opened) = await _sealedPost(_suploadUrl, inner);
    if (status == 200 && opened != null) return true;
    // Any failure here is ambiguous: the host rejected the transfer (413
    // over the size limit, 400 malformed/rejected multipart) OR our
    // envelope no longer opens there (wrong key / sealed endpoints gone).
    // [_confirmPinUsable] settles it: stale pin -> exception (host is
    // dropped), healthy pin -> plain rejection (host is kept).
    await _confirmPinUsable();
    return false;
  }

  /// Download a file. Returns the raw bytes.
  ///
  /// A 404 here means the file is missing, not that the server is gone, so it
  /// raises a plain [HttpException].
  Future<Uint8List> downloadFile(String name) async {
    if (hostKey != null) return _downloadFileSealed(name);
    final req = await _http.getUrl(Uri.parse(downloadUrl(name)));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('download failed: ${res.statusCode}');
    }
    return _readAll(res);
  }

  Future<Uint8List> _downloadFileSealed(String name) async {
    final result = await _sealedPost(_sflUrl, Uint8List.fromList(utf8.encode(name)));
    final (status, opened) = result;
    if (status == 200 && opened != null) return opened;
    if (status == 404) {
      // The host opened our envelope and answered a path-level 404: only
      // the file is missing, the pin works — plain error, host is kept.
      throw HttpException('sealed download failed: file not found (404)');
    }
    // Ambiguous (envelope rejected, response not authenticated, server
    // error): confirm the pin — stale pin -> exception (host dropped),
    // healthy pin -> plain error (host kept).
    await _confirmPinUsable();
    throw HttpException(status == 200
        ? 'sealed download failed: response did not authenticate'
        : 'sealed download failed: $status');
  }

  Future<Uint8List> _readAll(HttpClientResponse res) async {
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
