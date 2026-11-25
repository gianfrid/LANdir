// HTTP server for the LANdir core, ported from landir.py's Handler.
// Uses dart:io HttpServer directly — no middleware — so the request
// handling stays byte-comparable with the Python reference.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'crypto.dart';
import 'file_sink.dart';
import 'multipart.dart';
import 'page.dart';
import 'security.dart';

/// Configuration for a LANdir server instance.
class ServerConfig {
  /// A valid requested port: 0-65535, where 0 delegates the choice to the
  /// host (it picks a random free dynamic-range port). One rule, shared by
  /// the port picker UI and the controller.
  static bool isValidPort(int port) => port >= 0 && port <= 65535;

  final int port;
  final String uploadDir;
  final bool insecure; // false = secret mode (random token path)
  final String? secretToken;
  final int? maxUploadBytes; // null = no limit (desktop parity)

  /// Encryption mode (app-host-only, ADR 0003): when true the host serves
  /// ONLY the sealed endpoints — every plaintext endpoint (page, files,
  /// ls, fl, upload) answers 404, so files are not readable without the
  /// host key carried in the QR fragment. When false the host behaves
  /// like a CLI host: plaintext everywhere, no sealed endpoints.
  final bool encrypted;

  ServerConfig({
    this.port = 8000,
    required this.uploadDir,
    this.insecure = false,
    this.secretToken,
    this.maxUploadBytes,
    this.encrypted = false,
  });

  String get pagePath => secretToken != null ? '/$secretToken/' : '/';
  String get uploadPath => secretToken != null ? '/$secretToken/upload' : '/upload';
  String get filesPath => '${pagePath}files';
  String get downloadPrefix => '${pagePath}fl/';
  String get listPrefix => '${pagePath}ls/';
}

/// A locally-picked file to write into the host's own sink (host-view
/// "Add files"): same sanitization and collision rules as remote uploads.
class LocalFile {
  final String name;
  final Uint8List bytes;
  const LocalFile(this.name, this.bytes);
}

/// Outcome of [saveLocalFiles]: how many files wrote, and why the rest
/// failed (per-file, so one bad name never blocks the batch).
class LocalFilesResult {
  final int ok;
  final List<String> failures;
  const LocalFilesResult(this.ok, this.failures);
  bool get allOk => failures.isEmpty;
}

/// Write [files] through [sink] exactly like an HTTP upload would:
/// safeName() first, then sink-level collision renaming ("stem (N).ext")
/// for storages (MediaStore) whose existing files safeName can't see.
Future<LocalFilesResult> saveLocalFiles(
    FileSink sink, String uploadDir, List<LocalFile> files) async {
  var ok = 0;
  final failures = <String>[];
  for (final f in files) {
    try {
      var name = safeName(f.name, uploadDir);
      var n = 1;
      while (await sink.exists(name)) {
        name = numberedName(safeName(f.name, uploadDir), n++);
      }
      await sink.write(name, Stream.value(f.bytes));
      ok++;
    } catch (e) {
      failures.add('${f.name}: $e');
    }
  }
  return LocalFilesResult(ok, failures);
}

/// A file from a picked folder tree: [path] is the relative path inside
/// the picked folder ("sub/photo.jpg"), preserved as the upload path.
class LocalPathFile {
  final String path;
  final Uint8List bytes;
  const LocalPathFile(this.path, this.bytes);
}

/// Like [saveLocalFiles] but preserves directory structure: [f.path] may
/// contain '/', is sanitized component-wise by sanitizeUploadPath(), and
/// collisions get the numbered suffix on the last component
/// ("sub/photo.jpg" → "sub/photo (1).jpg").
Future<LocalFilesResult> saveLocalPaths(
    FileSink sink, String uploadDir, List<LocalPathFile> files) async {
  var ok = 0;
  final failures = <String>[];
  for (final f in files) {
    try {
      final cleaned = sanitizeUploadPath(f.path, uploadDir);
      if (cleaned == null) {
        failures.add('${f.path}: rejected');
        continue;
      }
      var rel = cleaned;
      var n = 1;
      while (await sink.exists(rel)) {
        rel = numberedName(rel, n++);
      }
      await sink.write(rel, Stream.value(f.bytes));
      ok++;
    } catch (e) {
      failures.add('${f.path}: $e');
    }
  }
  return LocalFilesResult(ok, failures);
}

/// A running LANdir server instance.
class LANdirServer {
  final ServerConfig config;
  final FileSink sink;

  /// The host's long-term X25519 key (design 001, M2). When null the server
  /// is keyless (e.g. started before this feature): the sealed endpoints
  /// answer 404 and the advertised URL carries no #k= fragment.
  final HostKey? hostKey;

  HttpServer? _httpServer;

  LANdirServer(this.config, this.sink, {this.hostKey});

  String get pagePath => config.pagePath;

  final _random = Random();

  Future<void> start() async {
    _httpServer = await _bindWithFallback(config.port);
    _httpServer!.listen(_handleRequest);
  }

  /// Mirror of landir.py's _find_available_port: try the requested port;
  /// an occupied request (or 0, which delegates the choice) falls back to
  /// up to 100 random drawers in the documented dynamic range 32768-60999.
  /// No OS-ephemeral binding: the reference and README pin that range.
  Future<HttpServer> _bindWithFallback(int requested) async {
    if (requested != 0) {
      try {
        return await HttpServer.bind(InternetAddress.anyIPv4, requested);
      } on SocketException {
        // occupied; fall through to the random draws
      }
    }
    const minPort = 32768, maxPort = 60999;
    Object? lastError;
    for (var i = 0; i < 100; i++) {
      final candidate = minPort + _random.nextInt(maxPort - minPort + 1);
      try {
        return await HttpServer.bind(InternetAddress.anyIPv4, candidate);
      } on SocketException catch (e) {
        lastError = e;
      }
    }
    throw StateError('no available port after 100 attempts: $lastError');
  }

  Future<void> stop() async {
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  int get boundPort => _httpServer?.port ?? config.port;

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final base = req.uri.path;
      if (req.method == 'GET') {
        await _handleGet(req, base);
      } else if (req.method == 'POST') {
        await _handlePost(req, base);
      } else {
        _sendError(req, 404);
      }
    } catch (_) {
      try {
        _sendError(req, 500);
      } catch (_) {}
    }
  }

  Future<void> _handleGet(HttpRequest req, String base) async {
    // Encryption mode: files must not be readable without the key — every
    // plaintext route (page included) is a blind 404, indistinguishable
    // from secret mode's unknown-path response.
    if (config.encrypted) {
      _sendError(req, 404);
      return;
    }
    final token = config.secretToken;
    if (token != null && base == '/$token') {
      // Redirect to add trailing slash so relative URLs resolve
      req.response.statusCode = 302;
      req.response.headers.set('Location', config.pagePath);
      req.response.headers.set('Content-Length', '0');
      await req.response.close();
      return;
    }
    if (base == config.pagePath || (token == null && base == '/index.html')) {
      _send(req, 200, utf8.encode(pageHtml),
          contentType: 'text/html; charset=utf-8');
      return;
    }
    if (base == config.filesPath) {
      final json = await _listingJsonBytes('');
      _send(req, 200, json, contentType: 'application/json');
      return;
    }
    if (base.startsWith(config.listPrefix)) {
      final relPath = base.substring(config.listPrefix.length);
      final json = await _listingJsonBytesForPath(relPath);
      if (json == null) {
        _sendError(req, 404);
        return;
      }
      _send(req, 200, json, contentType: 'application/json');
      return;
    }
    if (base.startsWith(config.downloadPrefix)) {
      final rel = sanitizeSinkPath(
          base.substring(config.downloadPrefix.length), config.uploadDir);
      if (rel == null) {
        _sendError(req, 404);
        return;
      }
      final stream = await sink.openRead(rel);
      final size = await sink.sizeOf(rel);
      if (stream == null || size == null) {
        _sendError(req, 404);
        return;
      }
      req.response.statusCode = 200;
      req.response.headers.set('Content-Type', 'application/octet-stream');
      req.response.headers.set('Content-Disposition',
          'attachment; filename="${rel.split('/').last}"');
      req.response.headers.set('Content-Length', size.toString());
      await stream.pipe(req.response);
      return;
    }
    _sendError(req, 404);
  }

  Future<void> _handlePost(HttpRequest req, String base) async {
    if (base != config.uploadPath) {
      await _handleSealedPost(req, base);
      return;
    }
    // Encryption mode: uploads are as sealed as reads (an unauthenticated
    // plaintext write is just as out of place as a plaintext read).
    if (config.encrypted) {
      _sendError(req, 404);
      return;
    }
    final ctype = req.headers.value('content-type') ?? '';
    final boundaryMatch = RegExp(r'boundary="?([^";]+)"?').firstMatch(ctype);
    if (boundaryMatch == null) {
      _sendError(req, 400);
      return;
    }
    final boundary = boundaryMatch.group(1)!;

    // Dart's contentLength is the parsed Content-Length, or -1 when unknown
    // (missing header, chunked encoding, or invalid value). Python rejects
    // negative/non-numeric Content-Length with 400; we detect those via the
    // raw header and reject. A genuinely missing header means an empty body
    // (Python treats it as 0).
    final rawLength = req.headers.value('content-length');
    if (rawLength != null) {
      final parsed = int.tryParse(rawLength);
      if (parsed == null || parsed < 0) {
        _sendError(req, 400);
        return;
      }
    }
    final length = req.contentLength;
    if (config.maxUploadBytes != null &&
        length > 0 &&
        length > config.maxUploadBytes!) {
      _sendError(req, 413);
      return;
    }

    final body = await _readBody(req);
    final saved = await _saveUploadedFiles(body, boundary);
    if (saved > 0) {
      _send(req, 200, utf8.encode('OK'), contentType: 'text/plain');
    } else {
      _sendError(req, 400);
    }
  }

  /// Buffers the full request body (dart:io streams it; the Python
  /// reference also reads the full body before parsing).
  Future<Uint8List> _readBody(HttpRequest req) => _collectStream(req);

  /// Parses [body] as multipart and writes every file through the sink.
  /// Returns how many files were saved. The decrypted filename still goes
  /// through safeName() — SPEC.md rule 1 is unchanged below the crypto layer.
  Future<int> _saveUploadedFiles(Uint8List body, String boundary) async {
    final files = parseMultipart(body, boundary);
    var saved = 0;
    for (final f in files) {
      try {
        var name = safeName(f.filename, config.uploadDir);
        // Sink-level collision check: on Android the real storage is
        // MediaStore, not uploadDir, so safeName's filesystem check can't
        // see existing files there. Rename ourselves as "stem (N).ext"
        // (extension preserved) instead of letting the OS produce
        // "name.ext (N)".
        var n = 1;
        while (await sink.exists(name)) {
          name = numberedName(safeName(f.filename, config.uploadDir), n++);
        }
        await sink.write(name, Stream.value(f.bytes));
        saved++;
      } catch (_) {
        continue;
      }
    }
    return saved;
  }

  // --- Sealed endpoints (design 001, M2) ---------------------------------
  //
  // All sealed endpoints are POST with body = request envelope
  // ('L' ‖ ephPub ‖ nonce ‖ ct+mac) and answer with a response envelope
  // ('L' ‖ nonce ‖ ct+mac). Decrypt first, then delegate into the same
  // logic as the plaintext endpoints. AEAD failure -> plain 400 (there is
  // no authenticated channel to seal an error into).
  //
  //   <pagePath>supload  plaintext = boundary '\r\n' + multipart body
  //   <pagePath>sfiles   plaintext = empty            -> sealed JSON listing
  //   <pagePath>sls      plaintext = UTF-8 dir path   -> sealed JSON listing
  //   <pagePath>sfl      plaintext = UTF-8 file path  -> sealed file bytes

  Future<void> _handleSealedPost(HttpRequest req, String base) async {
    final host = hostKey;
    final p = config.pagePath;
    final isSealed = host != null &&
        config.encrypted &&
        (base == '${p}supload' ||
            base == '${p}sfiles' ||
            base == '${p}sls' ||
            base == '${p}sfl');
    if (!isSealed) {
      _sendError(req, 404);
      return;
    }
    final envelope = await _readBody(req);
    final plain = await openAtHost(envelope, host);
    if (plain == null) {
      _sendError(req, 400);
      return;
    }
    // The size limit applies to the decrypted payload, not the (larger)
    // envelope that carries it.
    if (config.maxUploadBytes != null && plain.length > config.maxUploadBytes!) {
      _sendError(req, 413);
      return;
    }
    final ephPub = ephPublicKeyOf(envelope);
    Future<void> respondSealed(List<int> plaintextPayload) async {
      final sealed = await sealResponse(
          Uint8List.fromList(plaintextPayload), ephPub, host);
      _send(req, 200, sealed,
          contentType: 'application/octet-stream');
    }

    if (base == '${p}supload') {
      // First line of the plaintext is the multipart boundary.
      final sep = plain.indexOf(0x0d); // '\r'
      if (sep < 0 || sep + 1 >= plain.length || plain[sep + 1] != 0x0a) {
        _sendError(req, 400);
        return;
      }
      final boundary = utf8.decode(plain.sublist(0, sep));
      final saved = await _saveUploadedFiles(
          Uint8List.sublistView(plain, sep + 2), boundary);
      if (saved > 0) {
        await respondSealed(utf8.encode('OK'));
      } else {
        _sendError(req, 400);
      }
      return;
    }
    if (base == '${p}sfiles' || base == '${p}sls') {
      final json = base == '${p}sfiles'
          ? await _listingJsonBytes('')
          : await _listingJsonBytesForPath(utf8.decode(plain));
      if (json == null) {
        _sendError(req, 404);
        return;
      }
      await respondSealed(json);
      return;
    }
    // sfl: sealed download
    final rel = sanitizeSinkPath(utf8.decode(plain), config.uploadDir);
    if (rel == null) {
      _sendError(req, 404);
      return;
    }
    final stream = await sink.openRead(rel);
    final size = await sink.sizeOf(rel);
    if (stream == null || size == null) {
      _sendError(req, 404);
      return;
    }
    await respondSealed(await _collectStream(stream));
  }

  /// Listing as JSON bytes; [relPath] '' lists the upload root.
  Future<List<int>> _listingJsonBytes(String relPath) async {
    final entries = await sink.list(relPath);
    return utf8.encode(jsonEncode(entries.map((e) => e.toJson()).toList()));
  }

  /// Nested-listing JSON bytes after sanitizing [rawRelPath]; null when the
  /// path is rejected or the directory doesn't exist (both 404, matching
  /// the Python reference).
  Future<List<int>?> _listingJsonBytesForPath(String rawRelPath) async {
    final sanitized = sanitizeSinkPath(rawRelPath, config.uploadDir);
    if (sanitized == null) return null;
    final dirPath = sanitized == '.' ? '' : sanitized;
    final dir = Directory(dirPath.isEmpty
        ? config.uploadDir
        : '${config.uploadDir}/$dirPath');
    if (!dir.existsSync()) return null;
    return _listingJsonBytes(dirPath);
  }

  Future<Uint8List> _collectStream(Stream<List<int>> stream) async {
    final chunks = <Uint8List>[];
    await for (final chunk in stream) {
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

  void _send(HttpRequest req, int status, List<int> body,
      {String? contentType}) {
    req.response.statusCode = status;
    if (contentType != null) {
      req.response.headers.set('Content-Type', contentType);
    }
    req.response.headers.set('Content-Length', body.length.toString());
    req.response.add(body);
    req.response.close();
  }

  void _sendError(HttpRequest req, int status) {
    req.response.statusCode = status;
    req.response.headers.set('Content-Length', '0');
    req.response.close();
  }
}
