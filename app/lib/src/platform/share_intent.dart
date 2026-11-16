// Adapter from the receive_sharing_intent plugin types to the pure
// [IncomingShare] model. Kept thin so all decisions are testable in core.

import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../core/share.dart';

/// Convert plugin share items into [IncomingShare]s.
///
/// Text and URL shares become text uploads — the plugin delivers their
/// content in `SharedMediaFile.path` (Android: `path ?: text`), so `text`
/// shares must be read from there, never treated as a file path. Everything
/// else is a file; the plugin has already copied content:// URIs into the
/// app cache.
List<IncomingShare> incomingSharesFromMedia(List<SharedMediaFile> media) {
  return media.map((f) {
    switch (f.type) {
      case SharedMediaType.text:
      case SharedMediaType.url:
        return IncomingShare.text(text: f.path);
      case SharedMediaType.image:
      case SharedMediaType.video:
      case SharedMediaType.file:
        return IncomingShare.file(
          filename: filenameFromSharePath(f.path),
          filePath: f.path,
        );
    }
  }).toList();
}
