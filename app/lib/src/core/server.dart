// HTTP server for the Landir core, ported from landir.py's Handler.
// Uses dart:io HttpServer directly — no middleware — so the request
// handling stays byte-comparable with the Python reference.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'file_sink.dart';
import 'multipart.dart';
import 'page.dart';
import 'security.dart';

/// Configuration for a Landir server instance.
class ServerConfig {
  final int port;
  final String uploadDir;
  final bool insecure; // false = secret mode (random token path)
  final String? secretToken;
  final int? maxUploadBytes; // null = no limit (desktop parity)

  ServerConfig({
    this.port = 8000,
    required this.uploadDir,
    this.insecure = false,
    this.secretToken,
    this.maxUploadBytes,
  });

  String get pagePath => secretToken != null ? '/$secretToken/' : '/';
  String get uploadPath => secretToken != null ? '/$secretToken/upload' : '/upload';
  String get filesPath => '${pagePath}files';
  String get downloadPrefix => '${pagePath}fl/';
  String get listPrefix => '${pagePath}ls/';
}

/// A running Landir server instance.
class LandirServer {
  final ServerConfig config;
  final FileSink sink;
  HttpServer? _httpServer;

  LandirServer(this.config, this.sink);

  String get pagePath => config.pagePath;

  Future<void> start() async {
    _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, config.port);
    _httpServer!.listen(_handleRequest);
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
      final entries = await sink.list('');
      _sendJson(req, entries.map((e) => e.toJson()).toList());
      return;
    }
    if (base.startsWith(config.listPrefix)) {
      final relPath = base.substring(config.listPrefix.length);
      final sanitized = sanitizeSinkPath(relPath, config.uploadDir);
      if (sanitized == null) {
        _sendError(req, 404);
        return;
      }
      final dirPath = sanitized == '.' ? '' : sanitized;
      // Nonexistent directory is a 404 (matches the Python reference).
      final dir = Directory(dirPath.isEmpty
          ? config.uploadDir
          : '${config.uploadDir}/$dirPath');
      if (!dir.existsSync()) {
        _sendError(req, 404);
        return;
      }
      final entries = await sink.list(dirPath);
      _sendJson(req, entries.map((e) => e.toJson()).toList());
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

    // Buffer the body (dart:io gives us a stream; we read it fully because
    // the Python reference also reads the full body before parsing).
    final chunks = <Uint8List>[];
    var total = 0;
    await for (final chunk in req) {
      chunks.add(Uint8List.fromList(chunk));
      total += chunk.length;
    }
    final body = Uint8List(total);
    var offset = 0;
    for (final chunk in chunks) {
      body.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }

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

    if (saved > 0) {
      _send(req, 200, utf8.encode('OK'), contentType: 'text/plain');
    } else {
      _sendError(req, 400);
    }
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

  void _sendJson(HttpRequest req, Object jsonData) {
    final body = utf8.encode(jsonEncode(jsonData));
    _send(req, 200, body, contentType: 'application/json');
  }

  void _sendError(HttpRequest req, int status) {
    req.response.statusCode = status;
    req.response.headers.set('Content-Length', '0');
    req.response.close();
  }
}
