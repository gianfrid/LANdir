// Adapter from the Android share-intake payload to the pure [IncomingShare]
// model. The payload is produced by MainActivity.kt (channel
// "landir/share_intent"): a JSON array of items, each either
// {"path", "filename"} for a file already copied into the app cache, or
// {"text"} for a plain-text share. Pure Dart (dart:convert only) so the
// parsing decisions are testable without a platform.

import 'dart:convert';

import '../core/share.dart';

/// Convert a share-intake JSON payload into [IncomingShare]s.
///
/// Malformed entries are skipped rather than thrown on: a broken item must
/// not lose the rest of the batch (the same rule the upload flow follows).
List<IncomingShare> incomingSharesFromPayload(String payload) {
  final decoded = jsonDecode(payload);
  if (decoded is! List) return const [];
  final shares = <IncomingShare>[];
  for (final entry in decoded) {
    if (entry is! Map<String, dynamic>) continue;
    final text = entry['text'];
    if (text is String && text.trim().isNotEmpty) {
      shares.add(IncomingShare.text(text: text));
      continue;
    }
    final path = entry['path'];
    final filename = entry['filename'];
    if (path is String && filename is String && path.isNotEmpty) {
      shares.add(IncomingShare.file(filename: filename, filePath: path));
    }
  }
  return shares;
}
