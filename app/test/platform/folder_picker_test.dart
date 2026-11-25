// Tests for the folder-tree adapter: the JSON wire format of the native
// listTree call, and the desktop (file://) walk used off Android.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:landir_app/src/platform/folder_picker.dart';

void main() {
  group('parseTreeEntries', () {
    test('parses the native JSON array into entries', () {
      const payload =
          '[{"relativePath":"a.txt","size":3},{"relativePath":"sub/b.bin","size":1024}]';
      final entries = parseTreeEntries(payload);
      expect(entries, hasLength(2));
      expect(entries[0].relativePath, 'a.txt');
      expect(entries[0].size, 3);
      expect(entries[1].relativePath, 'sub/b.bin');
      expect(entries[1].size, 1024);
    });

    test('tolerates a non-array payload and missing size', () {
      expect(parseTreeEntries('{}'), isEmpty);
      expect(parseTreeEntries('[{"relativePath":"x"}]').single.size, 0);
    });
  });

  // Off Android (tests run on the desktop VM) listFolderTree/readTreeFile
  // use the dart:io file:// branch.
  group('desktop tree walk', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('landir_tree_');
      File('${root.path}/top.txt').writeAsBytesSync([1]);
      Directory('${root.path}/sub').createSync();
      File('${root.path}/sub/nested.bin')
          .writeAsBytesSync(Uint8List.fromList([2, 3]));
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('listFolderTree returns every file with its relative path', () async {
      final entries = await listFolderTree(Uri.file(root.path));
      final paths = entries.map((e) => e.relativePath).toList()..sort();
      expect(paths, ['sub/nested.bin', 'top.txt']);
      expect(entries.firstWhere((e) => e.relativePath == 'sub/nested.bin').size, 2);
    });

    test('readTreeFile reads by relative path', () async {
      final bytes = await readTreeFile(Uri.file(root.path), 'sub/nested.bin');
      expect(bytes, [2, 3]);
    });
  });
}
