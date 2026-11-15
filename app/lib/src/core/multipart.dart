// Byte-level multipart/form-data parser, ported from landir.py do_POST().
// Golden fixtures from the Python side define the exact expected behavior;
// "almost right" corrupts files.

import 'dart:convert';
import 'dart:typed_data';

/// One parsed file part from a multipart body.
class MultipartFile {
  final String filename;
  final Uint8List bytes;

  const MultipartFile(this.filename, this.bytes);
}

/// Find the first occurrence of [pattern] in [haystack] starting at [start].
/// Returns -1 if not found.
int _indexOfBytes(Uint8List haystack, List<int> pattern, [int start = 0]) {
  if (pattern.isEmpty) return start;
  final max = haystack.length - pattern.length;
  for (var i = start; i <= max; i++) {
    var match = true;
    for (var j = 0; j < pattern.length; j++) {
      if (haystack[i + j] != pattern[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

/// Split [haystack] on every occurrence of [delimiter], returning the chunks
/// between delimiters (like Python's bytes.split).
List<Uint8List> _splitBytes(Uint8List haystack, List<int> delimiter) {
  final parts = <Uint8List>[];
  var start = 0;
  while (true) {
    final idx = _indexOfBytes(haystack, delimiter, start);
    if (idx < 0) {
      parts.add(haystack.sublist(start));
      break;
    }
    parts.add(haystack.sublist(start, idx));
    start = idx + delimiter.length;
  }
  return parts;
}

/// Extract the raw filename bytes from a Content-Disposition header blob.
/// Matches Python's re.search(rb'filename="([^"]*)"', header_blob).
Uint8List? _extractFilename(Uint8List headerBlob) {
  const needle = 'filename="';
  final needleBytes = needle.codeUnits;
  final idx = _indexOfBytes(headerBlob, needleBytes, 0);
  if (idx < 0) return null;
  final contentStart = idx + needleBytes.length;
  var end = contentStart;
  while (end < headerBlob.length && headerBlob[end] != 0x22 /* " */) {
    end++;
  }
  if (end >= headerBlob.length) return null;
  return headerBlob.sublist(contentStart, end);
}

/// Parse a multipart/form-data body. [body] is the full request body;
/// [boundary] is the boundary string from the Content-Type header (without
/// the leading "--"). Returns the file parts that carry a filename.
///
/// Mirrors the Python parser exactly: split on b"--" + boundary, require
/// "filename=" in the part, split header/body at the first CRLFCRLF, strip
/// the trailing CRLF from the file data.
List<MultipartFile> parseMultipart(Uint8List body, String boundary) {
  final delimiter = <int>[...utf8DashDash, ...boundary.codeUnits];
  final parts = _splitBytes(body, delimiter);
  final files = <MultipartFile>[];

  for (final part in parts) {
    // Skip parts without filename=
    if (_indexOfBytes(part, 'filename='.codeUnits) < 0) continue;
    try {
      // partition on first \r\n\r\n
      final sep = _indexOfBytes(part, crlfcrlf);
      if (sep < 0) continue;
      final headerBlob = part.sublist(0, sep);
      var filedata = part.sublist(sep + 4);
      // rsplit(b"\r\n", 1)[0]: strip one trailing CRLF
      if (filedata.length >= 2 &&
          filedata[filedata.length - 2] == 0x0d &&
          filedata[filedata.length - 1] == 0x0a) {
        filedata = filedata.sublist(0, filedata.length - 2);
      }
      final filenameBytes = _extractFilename(headerBlob);
      if (filenameBytes == null) continue;
      // Decode filename as UTF-8 with replacement (like Python's
      // nm.decode("utf-8", "replace"))
      final decoded = const Utf8Decoder(allowMalformed: true).convert(filenameBytes);
      files.add(MultipartFile(decoded, filedata));
    } catch (_) {
      continue;
    }
  }
  return files;
}

const List<int> utf8DashDash = [0x2d, 0x2d]; // "--"
const List<int> crlfcrlf = [0x0d, 0x0a, 0x0d, 0x0a]; // "\r\n\r\n"
