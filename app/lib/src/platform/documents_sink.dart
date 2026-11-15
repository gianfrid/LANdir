// FileSink for iOS (and desktop fallback): writes to the app's Documents
// directory, which is visible in the Files app when Info.plist sets
// UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace.

import 'package:path_provider/path_provider.dart';

import '../core/file_sink.dart';

class DocumentsFileSink extends DirectoryFileSink {
  DocumentsFileSink._(super.rootDir);

  static Future<DocumentsFileSink> create() async {
    final dir = await getApplicationDocumentsDirectory();
    return DocumentsFileSink._(dir.path);
  }
}
