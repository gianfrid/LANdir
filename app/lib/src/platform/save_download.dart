// Save a downloaded file to user-visible storage:
// Android → MediaStore.Downloads (Files app), iOS/desktop → app Documents.

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../core/security.dart';
import '../platform_channels.dart';

/// What to do when a download target already exists on the device.
enum CollisionAction {
  /// Save as "stem (N).ext" (extension preserved), keeping both files.
  rename,

  /// Replace the existing file's contents, keeping the original name.
  overwrite,
}

/// Result of [saveDownload]: the final on-device [name] (renamed on
/// collision) and a human-readable [where] description.
final class SavedDownload {
  const SavedDownload(this.name, this.where);
  final String name;
  final String where;
}

/// Whether a file called [name] already exists in the local download
/// location.
Future<bool> downloadExists(String name) async {
  if (Platform.isAndroid) return _mediaStoreFileExists(name);
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/$name').existsSync();
}

/// Persist [bytes] as [name] in the platform's user-visible download location.
/// On collision, [onCollision] decides between renaming to "stem (N).ext"
/// (extension preserved — MediaStore would otherwise produce "name.ext (N)",
/// which no file manager recognizes by extension) or overwriting in place.
Future<SavedDownload> saveDownload(
  String name,
  Uint8List bytes, {
  CollisionAction onCollision = CollisionAction.rename,
}) async {
  if (Platform.isAndroid) {
    var finalName = name;
    if (onCollision == CollisionAction.rename) {
      var n = 1;
      while (await _mediaStoreFileExists(finalName)) {
        finalName = numberedName(name, n++);
      }
    }
    await mediaStoreChannel.invokeMethod<String>('writeFile', {
      'name': finalName,
      'bytes': bytes,
      'overwrite': onCollision == CollisionAction.overwrite,
    });
    return SavedDownload(finalName, 'Downloads/$finalName');
  }
  final dir = await getApplicationDocumentsDirectory();
  var finalName = name;
  if (onCollision == CollisionAction.rename) {
    var n = 1;
    while (File('${dir.path}/$finalName').existsSync()) {
      finalName = numberedName(name, n++);
    }
  }
  final file = File('${dir.path}/$finalName');
  await file.writeAsBytes(bytes);
  return SavedDownload(finalName, file.path);
}

Future<bool> _mediaStoreFileExists(String name) async {
  try {
    return await mediaStoreChannel.invokeMethod<bool>('fileExists', {
          'name': name,
        }) ==
        true;
  } catch (_) {
    return false;
  }
}

/// Open a previously saved download with the platform's default app.
/// Android: fires ACTION_VIEW with the MediaStore content URI.
/// iOS/desktop: not supported — returns false (file is in the Files app).
Future<bool> openDownloadedFile(String name) async {
  if (!Platform.isAndroid) return false;
  try {
    return await mediaStoreChannel.invokeMethod<bool>('openFile', {
          'name': name,
        }) ==
        true;
  } catch (_) {
    return false;
  }
}
