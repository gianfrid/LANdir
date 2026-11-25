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
