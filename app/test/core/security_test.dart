// Tests for security.dart against golden vectors exported from landir.py.

import 'dart:convert';
import 'dart:io';

import 'package:landir_app/src/core/security.dart';
import 'package:test/test.dart';

late String tmpDir;

List<dynamic> loadFixture(String name) {
  final file = File('test/fixtures/$name');
  return jsonDecode(file.readAsStringSync()) as List<dynamic>;
}

void main() {
  setUpAll(() {
    tmpDir = Directory.systemTemp.createTempSync('landir_test_').path;
  });

  tearDownAll(() {
    Directory(tmpDir).deleteSync(recursive: true);
  });

  group('safeName golden vectors', () {
    final vectors = loadFixture('safe_name.json');
    for (final v in vectors) {
      final input = v['input'] as String;
      test('safeName(${jsonEncode(input)})', () {
        final kind = v['kind'] as String;
        if (kind == 'exact') {
          expect(safeName(input, tmpDir), v['output']);
        } else if (kind == 'pattern') {
          final pattern = RegExp(v['pattern'] as String);
          expect(pattern.hasMatch(safeName(input, tmpDir)), isTrue,
              reason: 'expected pattern ${v['pattern']} for input $input');
        } else if (kind == 'error') {
          expect(() => safeName(input, tmpDir), throwsArgumentError);
        }
      });
    }

    test('collision adds timestamp suffix (pattern)', () {
      final fixture =
          jsonDecode(File('test/fixtures/safe_name_collision.json').readAsStringSync())
              as Map<String, dynamic>;
      final input = fixture['input'] as String;
      // Create the file so a collision occurs
      File('$tmpDir/$input').writeAsStringSync('existing');
      final result = safeName(input, tmpDir);
      final pattern = RegExp(fixture['pattern'] as String);
      expect(pattern.hasMatch(result), isTrue);
      File('$tmpDir/$input').deleteSync();
    });

    test('numberedName preserves the extension before the counter', () {
      expect(numberedName('myphoto.jpg', 1), 'myphoto (1).jpg');
      expect(numberedName('myphoto.jpg', 12), 'myphoto (12).jpg');
      expect(numberedName('archive.tar.gz', 2), 'archive.tar (2).gz');
      expect(numberedName('noext', 1), 'noext (1)');
    });
  });

  group('downloadLookup golden vectors', () {
    setUp(() {
      // Recreate the same layout the export script used
      Directory('$tmpDir/folder/sub').createSync(recursive: true);
      for (final rel in [
        'normal.txt',
        'folder/file.txt',
        'folder/sub/file.txt',
        'with space.txt',
        'semi;colon.txt',
        'unicode_é.txt',
      ]) {
        File('$tmpDir/$rel').writeAsStringSync('content of $rel');
      }
      File('$tmpDir/.hidden').writeAsStringSync('secret');
    });

    final vectors = loadFixture('download_lookup.json');
    for (final v in vectors) {
      final input = v['input'] as String;
      test('downloadLookup(${jsonEncode(input)})', () {
        final result = downloadLookup(input, tmpDir);
        if (v['found'] == true) {
          expect(result, isNotNull);
          expect(result!.endsWith(v['rel'] as String), isTrue,
              reason: 'expected $result to end with ${v['rel']}');
        } else {
          expect(result, isNull);
        }
      });
    }
  });
}
