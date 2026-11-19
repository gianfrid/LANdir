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
