// Save a downloaded file to user-visible storage:
// Android → MediaStore.Downloads (Files app), iOS/desktop → app Documents.

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../platform_channels.dart';

/// Persist [bytes] as [name] in the platform's user-visible download location.
/// Returns a human-readable description of where it landed.
Future<String> saveDownload(String name, Uint8List bytes) async {
  if (Platform.isAndroid) {
    await mediaStoreChannel.invokeMethod<String>('writeFile', {
      'name': name,
      'bytes': bytes,
    });
    return 'Downloads/$name';
  }
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  return file.path;
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
