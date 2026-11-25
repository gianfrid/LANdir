// Storage abstraction: the server core writes received files through a
// FileSink and never touches platform APIs directly.

import 'dart:io';

/// Where received files are stored.
abstract class FileSink {
  /// Store [bytes] under [name] (already sanitized by safeName).
  /// Returns the path or identifier the file was stored as.
  Future<String> write(String name, Stream<List<int>> bytes);

  /// Resolve a download name to a file, or null if not found.
  /// Mirrors downloadLookup but against the sink's storage.
  Future<File?> resolve(String name);

  /// Open a stored file for reading, or null if not found.
  /// Works for sinks whose storage isn't a plain filesystem (MediaStore).
  Future<Stream<List<int>>?> openRead(String name);

  /// Size in bytes of a stored file, or null if not found.
  Future<int?> sizeOf(String name);

  /// Whether a file with [name] already exists in this sink's storage.
  /// Used for collision resolution so duplicates get a timestamp suffix
  /// instead of an OS-level " (1)" rename.
  Future<bool> exists(String name);

  /// Whether [relPath] ('' = root) is an existing directory in this sink's
  /// storage. The server core uses this instead of touching the filesystem
  /// itself: on app hosts the sink root is NOT the uploadDir (MediaStore on
  /// Android, Documents on iOS/desktop), so a local check would always miss.
  Future<bool> isDir(String relPath);

  /// List entries in a directory (relative path, '' for root).
  Future<List<FileEntry>> list(String relPath);
}

/// A directory entry for listings.
class FileEntry {
  final String name;
  final int size;
  final bool isDir;
  final DateTime mtime;

  const FileEntry({
    required this.name,
    required this.size,
    required this.isDir,
    required this.mtime,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'size': size,
        'is_dir': isDir,
        'mtime': mtime.millisecondsSinceEpoch / 1000,
      };
}

/// FileSink backed by a local directory (used in tests and as the base
/// for platform-specific sinks).
class DirectoryFileSink implements FileSink {
  final String rootDir;

  DirectoryFileSink(this.rootDir) {
    Directory(rootDir).createSync(recursive: true);
  }

  @override
  Future<String> write(String name, Stream<List<int>> bytes) async {
    final file = File('$rootDir/$name');
    // Folder uploads carry relative paths ("sub/file.txt") — the parent
    // directories may not exist yet.
    file.parent.createSync(recursive: true);
    final sink = file.openWrite();
    await bytes.pipe(sink);
    return file.path;
  }

  @override
  Future<File?> resolve(String name) async {
    final file = File('$rootDir/$name');
    if (await file.exists() && !await Directory(file.path).exists()) {
      return file;
    }
    return null;
  }

  @override
  Future<Stream<List<int>>?> openRead(String name) async {
    final file = File('$rootDir/$name');
    if (await file.exists() && !await Directory(file.path).exists()) {
      return file.openRead();
    }
    return null;
  }

  @override
  Future<int?> sizeOf(String name) async {
    final file = File('$rootDir/$name');
    if (await file.exists() && !await Directory(file.path).exists()) {
      return file.length();
    }
    return null;
  }

  @override
  Future<bool> exists(String name) async {
    final file = File('$rootDir/$name');
    return file.existsSync() && !FileSystemEntity.isDirectorySync(file.path);
  }

  @override
  Future<bool> isDir(String relPath) async {
    final dir =
        relPath.isEmpty ? Directory(rootDir) : Directory('$rootDir/$relPath');
    return dir.existsSync();
  }

  @override
  Future<List<FileEntry>> list(String relPath) async {
    final dir = relPath.isEmpty ? Directory(rootDir) : Directory('$rootDir/$relPath');
    if (!await dir.exists()) return [];
    final entries = <FileEntry>[];
    await for (final entity in dir.list()) {
      final stat = await entity.stat();
      entries.add(FileEntry(
        name: entity.path.split('/').last,
        size: entity is File ? stat.size : 0,
        isDir: entity is Directory,
        mtime: stat.modified,
      ));
    }
    entries.sort((a, b) => b.mtime.compareTo(a.mtime));
    return entries;
  }
}
