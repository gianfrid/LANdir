// Tests for multipart.dart against golden vectors exported from landir.py.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:landir_app/src/core/multipart.dart';
import 'package:test/test.dart';

List<dynamic> loadFixture(String name) {
  final file = File('test/fixtures/$name');
  return jsonDecode(file.readAsStringSync()) as List<dynamic>;
}

Uint8List hexToBytes(String hex) {
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

void main() {
  group('parseMultipart golden vectors', () {
    final vectors = loadFixture('multipart.json');
    for (final v in vectors) {
      final name = v['name'] as String;
      test(name, () {
        final boundary = v['boundary'] as String;
        final body = hexToBytes(v['body_hex'] as String);
        final expected = (v['expected'] as List<dynamic>)
            .map((e) => e as Map<String, dynamic>)
            .toList();

        final files = parseMultipart(body, boundary);

        expect(files.length, expected.length,
            reason: 'part count mismatch for $name');
        for (var i = 0; i < expected.length; i++) {
          expect(files[i].filename, expected[i]['filename'],
              reason: 'filename mismatch in $name part $i');
          expect(files[i].bytes, hexToBytes(expected[i]['data_hex'] as String),
              reason: 'data mismatch in $name part $i');
        }
      });
    }
  });
}
