// FileSink for iOS and desktop fallback: writes to the app's Documents
// directory, which is visible in the Files app when Info.plist sets
// UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace.
//
// On desktop the user can choose a different directory (Save directory,
// GLOSSARY): DocumentsFileSink.withRootDir targets that instead.

import 'package:path_provider/path_provider.dart';

import '../core/file_sink.dart';

class DocumentsFileSink extends DirectoryFileSink {
  DocumentsFileSink._(super.rootDir);

  static Future<DocumentsFileSink> create() async {
    final dir = await getApplicationDocumentsDirectory();
    return DocumentsFileSink._(dir.path);
  }

  /// Sink rooted at a user-chosen directory (created if missing), used
  /// instead of the Documents directory on desktop platforms.
  static DocumentsFileSink withRootDir(String rootDir) =>
      DocumentsFileSink._(rootDir);
}
