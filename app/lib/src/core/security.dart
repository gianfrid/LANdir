// Security-critical filename sanitization, ported byte-for-byte from
// landir.py (the reference implementation). Do not relax the whitelist.

import 'dart:convert';
import 'dart:io';

// Allowed characters, verified byte-for-byte against the Python regex
// [^A-Za-z0-9._ ()\[\]-]: space, (, ), -, ., 0-9, A-Z, [, ], _, a-z.
final RegExp _disallowedChar = RegExp(r'[^A-Za-z0-9._ ()\[\]-]');
final RegExp _allowedFull = RegExp(r'^[A-Za-z0-9._ ()\[\]-]+$');
final RegExp _controlChars = RegExp('[\x00-\x1f\x7f]');

/// Percent-decode like Python's urllib.parse.unquote (UTF-8, errors=replace,
/// no '+' handling). Invalid %XX sequences are left literal; invalid UTF-8
/// bytes become U+FFFD.
String percentDecode(String s) {
  if (!s.contains('%')) return s;
  final out = <int>[];
  var i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c == 0x25 && i + 2 < s.length) {
      final val = int.tryParse(s.substring(i + 1, i + 3), radix: 16);
      if (val != null) {
        out.add(val);
        i += 3;
        continue;
      }
    }
    // Encode the full rune at this position so surrogate pairs (emoji etc.)
    // survive intact, matching Python's per-code-point unquote behavior.
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
      out.addAll(utf8.encode(s.substring(i, i + 2)));
      i += 2;
    } else {
      out.addAll(utf8.encode(s[i]));
      i++;
    }
  }
  return utf8.decode(out, allowMalformed: true);
}

/// os.path.basename after backslash normalization (POSIX split on '/').
String _basename(String path) {
  final parts = path.split('/');
  return parts.isEmpty ? '' : parts.last;
}

/// os.path.splitext: split at the last dot, ignoring a leading dot.
(String, String) _splitext(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return (name, '');
  return (name.substring(0, dot), name.substring(dot));
}

/// Resolve symlinks like os.path.realpath. Works for non-existent paths
/// by resolving the parent directory and appending the basename.
String _realpath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } catch (_) {
    final parent = Directory(path).parent;
    final resolvedParent =
        parent.existsSync() ? parent.resolveSymbolicLinksSync() : parent.path;
    final base = _basename(path);
    return base.isEmpty ? resolvedParent : '$resolvedParent/$base';
  }
}

/// os.path.commonpath for two absolute POSIX paths.
String _commonpath(String a, String b) {
  final aParts = a.split('/').where((s) => s.isNotEmpty).toList();
  final bParts = b.split('/').where((s) => s.isNotEmpty).toList();
  final common = <String>[];
  for (var i = 0; i < aParts.length && i < bParts.length; i++) {
    if (aParts[i] != bParts[i]) break;
    common.add(aParts[i]);
  }
  if (common.isEmpty) {
    throw ArgumentError('paths have no common prefix: $a vs $b');
  }
  return '/${common.join('/')}';
}

/// Check that [path] resolves to a location inside [uploadDir].
bool insideUploads(String path, String uploadDir) {
  final real = _realpath(uploadDir);
  try {
    return _commonpath(_realpath(path), real) == real;
  } catch (_) {
    return false;
  }
}

/// Replace each disallowed code point with '_', one per rune (not per
/// UTF-16 code unit), matching Python's regex behavior on code points.
String _replaceDisallowed(String s) {
  final buffer = StringBuffer();
  for (final rune in s.runes) {
    final ch = String.fromCharCode(rune);
    buffer.write(_disallowedChar.hasMatch(ch) ? '_' : ch);
  }
  return buffer.toString();
}

/// Format a DateTime like Python's strftime('%Y%m%d_%H%M%S') or with '_%f'
/// (6-digit microseconds) appended.
String _fmtTimestamp(DateTime dt, {bool withMicros = false}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final base =
      '${dt.year.toString().padLeft(4, '0')}${two(dt.month)}${two(dt.day)}'
      '_${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
  if (!withMicros) return base;
  final us = (dt.microsecondsSinceEpoch % 1000000).toString().padLeft(6, '0');
  return '${base}_$us';
}

/// Apply the collision suffix to [name]: stem_yyyyMMdd_HHmmss.ext.
/// Port of the timestamp branch of landir.py safe_name().
String timestampedName(String name) {
  final (stem, ext) = _splitext(name);
  return '${stem}_${_fmtTimestamp(DateTime.now())}$ext';
}

/// Numbered collision name with the extension preserved:
/// "myphoto.jpg" → "myphoto (1).jpg". Used for sink-level collisions
/// (e.g. MediaStore on Android) where the OS rename would otherwise
/// produce "myphoto.jpg (1)" and break the extension.
String numberedName(String name, int n) {
  final (stem, ext) = _splitext(name);
  return '$stem ($n)$ext';
}

/// Sanitize an uploaded filename. Port of landir.py safe_name().
///
/// Returns the bare filename to write inside [uploadDir], or throws
/// [ArgumentError] if the resolved path escapes the upload directory.
String safeName(String name, String uploadDir) {
  // Decode, reduce to a bare filename: kills ../, ..\, absolute paths
  var n = percentDecode(name).replaceAll('\\', '/');
  n = _basename(n);
  // Strip control chars and NUL bytes
  n = n.replaceAll(_controlChars, '').trim();
  // Reject hidden and dot-only names
  n = n.replaceFirst(RegExp(r'^\.+'), '');
  // Only keep whitelisted characters; everything else becomes '_'.
  // Iterate by rune so supplementary-plane chars (emoji etc.) count as
  // one character, matching Python's per-code-point regex behavior.
  n = _replaceDisallowed(n);
  if (n.isEmpty || n.replaceAll('.', '').isEmpty) {
    n = 'file_${_fmtTimestamp(DateTime.now(), withMicros: true)}';
  }
  // Defense in depth: resolved path MUST stay inside uploadDir
  final path = _realpath('$uploadDir/$n');
  if (_commonpath(path, _realpath(uploadDir)) != _realpath(uploadDir)) {
    throw ArgumentError('path escapes upload directory');
  }
  // Avoid overwriting: add a timestamp suffix if the file exists
  var result = n;
  if (File(path).existsSync()) {
    final (stem, ext) = _splitext(n);
    result = '${stem}_${_fmtTimestamp(DateTime.now())}$ext';
  }
  return result;
}

/// Sanitize a single path component. Port of landir.py _safe_path_component().
/// Returns the sanitized component, or '' if invalid.
String safePathComponent(String name) {
  var n = percentDecode(name).replaceAll('\\', '/');
  n = _basename(n);
  n = n.replaceAll(_controlChars, '').trim();
  if (n.isEmpty || n.startsWith('.')) return '';
  if (!_allowedFull.hasMatch(n)) return '';
  return n;
}

/// Sanitize a relative upload path that may contain directories (folder
/// uploads from the host-view "Add folder"): each '/'-separated component
/// goes through the SAME whitelist as safeName() (control chars stripped,
/// leading dots removed, disallowed chars replaced with '_'), and the
/// resolved path must stay inside [uploadDir]. Returns the cleaned
/// relative path, or null when every component is rejected.
String? sanitizeUploadPath(String raw, String uploadDir) {
  final n = percentDecode(raw).replaceAll('\\', '/');
  final parts = <String>[];
  for (final part in n.split('/')) {
    var c = part.replaceAll(_controlChars, '').trim();
    c = c.replaceFirst(RegExp(r'^\.+'), '');
    c = _replaceDisallowed(c);
    if (c.isEmpty || c.replaceAll('.', '').isEmpty) return null;
    parts.add(c);
  }
  if (parts.isEmpty) return null;
  final rel = parts.join('/');
  if (!insideUploads('$uploadDir/$rel', uploadDir)) return null;
  return rel;
}

/// Resolve a client-requested download path to a file inside [uploadDir].
/// Port of landir.py download_lookup(). Returns the absolute path, or null
/// if the name is rejected.
String? downloadLookup(String raw, String uploadDir) {
  final decoded = percentDecode(raw);
  final parts = decoded.split('/');
  final sanitized = <String>[];
  for (final part in parts) {
    final s = safePathComponent(part);
    if (s.isEmpty) return null;
    sanitized.add(s);
  }
  if (sanitized.isEmpty) return null;
  final path = [uploadDir, ...sanitized].join('/');
  if (!insideUploads(path, uploadDir)) return null;
  if (!File(path).existsSync() || FileSystemEntity.isDirectorySync(path)) {
    return null;
  }
  return path;
}

/// Sanitize a client-requested path into a relative path safe for a FileSink.
/// Same rules as downloadLookup but without the filesystem isfile check —
/// the sink decides whether the target exists. Returns null if rejected.
String? sanitizeSinkPath(String raw, String uploadDir) {
  final decoded = percentDecode(raw);
  final parts = decoded.split('/');
  final sanitized = <String>[];
  for (final part in parts) {
    final s = safePathComponent(part);
    if (s.isEmpty) return null;
    sanitized.add(s);
  }
  if (sanitized.isEmpty) return null;
  final rel = sanitized.join('/');
  final path = '$uploadDir/$rel';
  if (!insideUploads(path, uploadDir)) return null;
  return rel;
}

/// Whether [host] from a server URL is a private, loopback, or link-local
/// address — i.e. consistent with LANdir's LAN-only design.
///
/// Accepts IPv4 literals (with the same private ranges [findLanAddresses]
/// treats as LAN), IPv6 loopback/link-local (fe80::/10, ::1), and single-
/// label or `.local` hostnames (typical for LAN hosts). Anything else —
/// public IPs, multi-label DNS names — returns false; callers warn.
bool isLanHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return false;
  if (h == 'localhost') return true;
  // IPv6 literals contain no dot, so they must be classified before the
  // single-label hostname check below would accept any of them.
  if (h.contains(':')) {
    if (h == '::1') return true;
    // fe80::/10 link-local: first group fe80-febf (1111111010xxxxxxxx).
    final m = RegExp(r'^fe[89ab][0-9a-f]:').firstMatch(h);
    return m != null;
  }
  if (h.endsWith('.local') || !h.contains('.')) return true;

  // IPv4 literal?
  final v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
      .firstMatch(h);
  if (v4 != null) {
    final octets = v4
        .groups([1, 2, 3, 4])
        .map((g) => int.parse(g!))
        .toList();
    if (octets.any((o) => o > 255)) return false;
    final a = octets[0], b = octets[1];
    return a == 10 ||
        a == 127 ||
        (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 169 && b == 254); // link-local
  }

  return false;
}
