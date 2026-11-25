// FileSink that writes received files to MediaStore.Downloads on Android,
// making them visible in the Files app and over USB without storage
// permissions (API 29+).

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/file_sink.dart';
import '../platform_channels.dart';

class MediaStoreFileSink implements FileSink {
  @override
  Future<String> write(String name, Stream<List<int>> bytes) async {
    final chunks = <Uint8List>[];
    await for (final chunk in bytes) {
      chunks.add(Uint8List.fromList(chunk));
    }
    final total = chunks.fold<int>(0, (sum, c) => sum + c.length);
    final data = Uint8List(total);
    var offset = 0;
    for (final c in chunks) {
      data.setRange(offset, offset + c.length, c);
      offset += c.length;
    }
    final result = await mediaStoreChannel.invokeMethod<String>('writeFile', {
      'name': name,
      'bytes': data,
    });
    return result ?? name;
  }

  @override
  Future<File?> resolve(String name) async {
    // MediaStore uses content:// URIs, not filesystem paths.
    return null;
  }

  @override
  Future<Stream<List<int>>?> openRead(String name) async {
    // Full relative path ("sub/file.txt"); the native side splits it into
    // RELATIVE_PATH + DISPLAY_NAME for the MediaStore query.
    try {
      final bytes = await mediaStoreChannel.invokeMethod<Uint8List>('readFile', {
        'name': name,
      });
      if (bytes == null) return null;
      return Stream.value(bytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int?> sizeOf(String name) async {
    try {
      return await mediaStoreChannel.invokeMethod<int>('fileSize', {
        'name': name,
      });
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> exists(String name) async {
    try {
      return await mediaStoreChannel.invokeMethod<bool>('fileExists', {
            'name': name,
          }) ==
          true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<FileEntry>> list(String relPath) async {
    try {
      final result = await mediaStoreChannel.invokeMethod<List<dynamic>>('listFiles');
      if (result == null) return [];
      return result.map((e) {
        final m = e as Map<dynamic, dynamic>;
        return FileEntry(
          name: m['name'] as String,
          size: (m['size'] as num).toInt(),
          isDir: false,
          mtime: DateTime.fromMillisecondsSinceEpoch(
              ((m['mtime'] as num) * 1000).toInt()),
        );
      }).toList()
        ..sort((a, b) => b.mtime.compareTo(a.mtime));
    } catch (e) {
      debugPrint('MediaStore listFiles failed: $e');
      return [];
    }
  }
}
