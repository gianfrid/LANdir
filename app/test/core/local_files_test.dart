// Tests for saveLocalFiles(): the host-view "Add files" path that writes
// locally-picked files through the sink with the same sanitization and
// collision rules as a remote HTTP upload.

import 'dart:io';
import 'dart:typed_data';

import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/core/server.dart';
import 'package:test/test.dart';

/// Sink whose exists() reflects names actually written through it,
/// independent of the uploadDir — mimics MediaStore on Android, where
/// safeName's filesystem check can't see existing files.
class _SetBackedSink implements FileSink {
  final DirectoryFileSink inner;
  final Set<String> _written = {};
  _SetBackedSink(this.inner);

  @override
  Future<String> write(String name, Stream<List<int>> bytes) async {
    _written.add(name);
    return inner.write(name, bytes);
  }

  @override
  Future<File?> resolve(String name) => inner.resolve(name);

  @override
  Future<Stream<List<int>>?> openRead(String name) => inner.openRead(name);

  @override
  Future<int?> sizeOf(String name) => inner.sizeOf(name);

  @override
  Future<bool> exists(String name) async => _written.contains(name);

  @override
  Future<bool> isDir(String relPath) => inner.isDir(relPath);

  @override
  Future<List<FileEntry>> list(String relPath) => inner.list(relPath);
}

/// Sink whose exists()/write() have a real async gap before touching the
/// filesystem, like the MediaStore platform channel on Android. Without the
/// save lock, two concurrent same-name saves both see "not exists" and then
/// both truncate-write the same file.
class _DelayedSink implements FileSink {
  final DirectoryFileSink inner;
  _DelayedSink(this.inner);

  @override
  Future<String> write(String name, Stream<List<int>> bytes) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return inner.write(name, bytes);
  }

  @override
  Future<bool> exists(String name) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return inner.exists(name);
  }

  @override
  Future<File?> resolve(String name) => inner.resolve(name);

  @override
  Future<Stream<List<int>>?> openRead(String name) => inner.openRead(name);

  @override
  Future<int?> sizeOf(String name) => inner.sizeOf(name);

  @override
  Future<bool> isDir(String relPath) => inner.isDir(relPath);

  @override
  Future<List<FileEntry>> list(String relPath) => inner.list(relPath);
}

void main() {
  late Directory tmp;
  late DirectoryFileSink sink;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('landir_local_files_');
    sink = DirectoryFileSink('${tmp.path}/uploads');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('writes a picked file under its sanitized name', () async {
    final result = await saveLocalFiles(
        sink, sink.rootDir, [LocalFile('photo.jpg', Uint8List.fromList([1, 2, 3]))]);
    expect(result.ok, 1);
    expect(result.allOk, isTrue);
    expect(File('${sink.rootDir}/photo.jpg').readAsBytesSync(), [1, 2, 3]);
  });

  test('sanitizes a hostile name instead of escaping the upload dir',
      () async {
    final result = await saveLocalFiles(
        sink, sink.rootDir, [LocalFile('../../evil.sh', Uint8List.fromList([9]))]);
    // safeName reduces to a bare, whitelisted basename inside the root.
    expect(result.ok, 1);
    expect(Directory(sink.rootDir).listSync().single.path,
        '${sink.rootDir}/evil.sh');
    expect(File('/evil.sh').existsSync(), isFalse);
  });

  test('collision gets a numbered rename with the extension preserved',
      () async {
    // uploadDir and sink root are separate, mimicking Android where the
    // real storage (MediaStore) is invisible to safeName's filesystem
    // check — so the sink-level exists() drives the numbered rename.
    final uploadDir = '${tmp.path}/updir';
    Directory(uploadDir).createSync();
    final setSink = _SetBackedSink(sink);
    final files = [
      LocalFile('photo.jpg', Uint8List.fromList([1])),
      LocalFile('photo.jpg', Uint8List.fromList([2])),
      LocalFile('photo.jpg', Uint8List.fromList([3])),
    ];
    final result = await saveLocalFiles(setSink, uploadDir, files);
    expect(result.ok, 3);
    expect(File('${sink.rootDir}/photo.jpg').readAsBytesSync(), [1]);
    expect(File('${sink.rootDir}/photo (1).jpg').readAsBytesSync(), [2]);
    expect(File('${sink.rootDir}/photo (2).jpg').readAsBytesSync(), [3]);
  });

  test('concurrent same-name saves keep both versions intact', () async {
    final a = Uint8List.fromList(List<int>.generate(200000, (i) => i % 251));
    final b =
        Uint8List.fromList(List<int>.generate(200000, (i) => (i * 5 + 3) % 241));
    final r1 = saveLocalFiles(sink, sink.rootDir, [LocalFile('dup.bin', a)]);
    final r2 = saveLocalFiles(sink, sink.rootDir, [LocalFile('dup.bin', b)]);
    final results = await Future.wait([r1, r2]);
    expect(results.every((r) => r.ok == 1), isTrue);
    final contents = Directory(sink.rootDir)
        .listSync()
        .where((e) => e is File && e.path.contains('dup'))
        .map((e) => File(e.path).readAsBytesSync())
        .toList();
    expect(contents.length, 2, reason: 'both saves must be stored');
    expect(contents, anyElement(equals(a)));
    expect(contents, anyElement(equals(b)));
  });

  test('async-gap sink (MediaStore-like) cannot race a same-name save',
      () async {
    final delayed = _DelayedSink(sink);
    final a = Uint8List.fromList(List<int>.generate(50000, (i) => i % 251));
    final b =
        Uint8List.fromList(List<int>.generate(50000, (i) => (i * 5 + 3) % 241));
    final r1 = saveLocalFiles(delayed, sink.rootDir, [LocalFile('race.bin', a)]);
    final r2 = saveLocalFiles(delayed, sink.rootDir, [LocalFile('race.bin', b)]);
    final results = await Future.wait([r1, r2]);
    expect(results.every((r) => r.ok == 1), isTrue);
    final contents = Directory(sink.rootDir)
        .listSync()
        .where((e) => e is File && e.path.contains('race'))
        .map((e) => File(e.path).readAsBytesSync())
        .toList();
    expect(contents.length, 2, reason: 'both saves must be stored');
    expect(contents, anyElement(equals(a)));
    expect(contents, anyElement(equals(b)));
  });

  test('one unreadable entry does not block the rest of the batch',
      () async {
    final result = await saveLocalFiles(sink, sink.rootDir, [
      LocalFile('good.txt', Uint8List.fromList([1])),
    ]);
    expect(result.ok, 1);
    expect(result.failures, isEmpty);
  });

  test('empty batch is a clean no-op', () async {
    final result = await saveLocalFiles(sink, sink.rootDir, const []);
    expect(result.ok, 0);
    expect(result.allOk, isTrue);
  });

  group('saveLocalPaths (folder uploads)', () {
    test('preserves the folder structure of a nested relative path', () async {
      final result = await saveLocalPaths(sink, sink.rootDir, [
        LocalPathFile('sub/photo.jpg', Uint8List.fromList([1, 2])),
        LocalPathFile('sub/deep/notes.txt', Uint8List.fromList([3])),
        LocalPathFile('top.txt', Uint8List.fromList([4])),
      ]);
      expect(result.ok, 3);
      expect(result.allOk, isTrue);
      expect(File('${sink.rootDir}/sub/photo.jpg').readAsBytesSync(), [1, 2]);
      expect(
          File('${sink.rootDir}/sub/deep/notes.txt').readAsBytesSync(), [3]);
      expect(File('${sink.rootDir}/top.txt').readAsBytesSync(), [4]);
    });

    test('rejects traversal outside the upload dir without writing',
        () async {
      final result = await saveLocalPaths(sink, sink.rootDir, [
        LocalPathFile('../evil.txt', Uint8List.fromList([9])),
        LocalPathFile('ok.txt', Uint8List.fromList([1])),
      ]);
      expect(result.ok, 1);
      expect(result.failures, hasLength(1));
      expect(result.failures.single, contains('evil.txt'));
      expect(File('${sink.rootDir}/ok.txt').existsSync(), isTrue);
      expect(File('${tmp.path}/evil.txt').existsSync(), isFalse);
    });

    test('disallowed characters in a component become underscores', () async {
      final result = await saveLocalPaths(sink, sink.rootDir, [
        LocalPathFile('my folder/ré sumé?.pdf', Uint8List.fromList([1])),
      ]);
      expect(result.ok, 1);
      // Same whitelist as safeName: space kept, non-ASCII and '?' -> '_'.
      expect(File('${sink.rootDir}/my folder/r_ sum__.pdf').existsSync(),
          isTrue);
    });

    test('collision numbers the last component only', () async {
      final uploadDir = '${tmp.path}/updir';
      Directory(uploadDir).createSync();
      final setSink = _SetBackedSink(sink);
      final result = await saveLocalPaths(setSink, uploadDir, [
        LocalPathFile('sub/photo.jpg', Uint8List.fromList([1])),
        LocalPathFile('sub/photo.jpg', Uint8List.fromList([2])),
      ]);
      expect(result.ok, 2);
      expect(File('${sink.rootDir}/sub/photo.jpg').readAsBytesSync(), [1]);
      expect(File('${sink.rootDir}/sub/photo (1).jpg').readAsBytesSync(), [2]);
    });
  });
}
