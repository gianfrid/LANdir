// Multipart writer: builds a multipart/form-data body for uploading files
// to a Landir server. The inverse of multipart.dart's parser.

import 'dart:convert';
import 'dart:typed_data';

/// Build a multipart/form-data body with a single file field named "file".
/// [boundary] must not appear in the file content.
/// Returns the body bytes and the boundary used.
({Uint8List body, String boundary}) buildMultipartBody({
  required String filename,
  required Uint8List content,
  String? boundary,
}) {
  final b = boundary ?? _randomBoundary();
  final parts = <int>[];
  parts.addAll('--$b\r\n'.codeUnits);
  parts.addAll(
      'Content-Disposition: form-data; name="file"; filename="$filename"\r\n'
          .codeUnits);
  parts.addAll('Content-Type: application/octet-stream\r\n\r\n'.codeUnits);
  parts.addAll(content);
  parts.addAll('\r\n--$b--\r\n'.codeUnits);
  return (body: Uint8List.fromList(parts), boundary: b);
}

String _randomBoundary() {
  final rng = DateTime.now().microsecondsSinceEpoch.toString() +
      DateTime.now().millisecondsSinceEpoch.toString();
  return '----landir${utf8.encode(rng).length}$rng';
}
