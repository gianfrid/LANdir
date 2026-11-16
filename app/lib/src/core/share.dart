// Share-sheet intake model. Pure Dart — no Flutter imports.

/// An item received through the platform share sheet, normalized for
/// upload to a Landir server. Either [filePath] or [text] is set.
class IncomingShare {
  /// Suggested upload filename.
  final String filename;

  /// Local path of the shared file. The platform layer has already copied
  /// content:// URIs into the app cache, so plain file reads work. Null for
  /// text shares.
  final String? filePath;

  /// Text content of a text/URL share, uploaded as a small text file.
  /// Null for file shares.
  final String? text;

  const IncomingShare.file({required this.filename, required this.filePath})
      : text = null;

  const IncomingShare.text({required this.text})
      : filename = 'shared.txt',
        filePath = null;

  bool get isText => text != null;
}

/// Extract the file name from a share-sheet file path. Handles both
/// separator styles; falls back to a generic name when the path has none.
String filenameFromSharePath(String path) {
  final name = path.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).lastOrNull;
  if (name == null || name.isEmpty) return 'shared-file';
  return name;
}
