// Folder picking for the host-view "Add folder": enumerate a picked
// directory tree and read its files, preserving each file's path relative
// to the picked root ("sub/photo.jpg").
//
// Android: FilePicker.pickDirectory() returns the SAF tree content:// URI,
// which only the native side can walk — see the landir/saf channel in
// MainActivity.kt. Desktop: a file:// URI walked with dart:io.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel safChannel = MethodChannel('landir/saf');

/// One file inside a picked folder tree.
class TreeEntry {
  /// Path relative to the picked root, '/'-separated ("sub/photo.jpg").
  final String relativePath;

  /// Size in bytes (informational; the actual read streams the bytes).
  final int size;

  const TreeEntry(this.relativePath, this.size);
}

/// Parse the JSON array produced by the native listTree call into entries.
/// Pure function so the wire format is unit-testable off-device.
List<TreeEntry> parseTreeEntries(String payload) {
  final decoded = jsonDecode(payload);
  if (decoded is! List) return [];
  return decoded
      .whereType<Map<String, dynamic>>()
      .map((e) => TreeEntry(
            e['relativePath'] as String,
            (e['size'] as num?)?.toInt() ?? 0,
          ))
      .toList();
}

/// Enumerate every regular file under the picked [treeUri].
Future<List<TreeEntry>> listFolderTree(Uri treeUri) async {
  if (Platform.isAndroid) {
    final payload = await safChannel.invokeMethod<String>('listTree', {
      'treeUri': treeUri.toString(),
    });
    if (payload == null) return [];
    return parseTreeEntries(payload);
  }
  // Desktop: file:// URI (or a bare path), walked with dart:io.
  final root = Directory(treeUri.toFilePath());
  final entries = <TreeEntry>[];
  await for (final entity
      in root.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      final rel = entity.path.substring(root.path.length + 1);
      entries.add(TreeEntry(rel, entity.lengthSync()));
    }
  }
  return entries;
}

/// Read one file from the picked tree by its [relativePath].
Future<Uint8List> readTreeFile(Uri treeUri, String relativePath) async {
  if (Platform.isAndroid) {
    final bytes = await safChannel.invokeMethod<Uint8List>('readTreeFile', {
      'treeUri': treeUri.toString(),
      'relativePath': relativePath,
    });
    if (bytes == null) throw StateError('cannot read $relativePath');
    return bytes;
  }
  return File('${treeUri.toFilePath()}/$relativePath').readAsBytes();
}
