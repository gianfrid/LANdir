// Tests for the Android share-intake payload parser (pure Dart): the
// JSON produced by MainActivity.kt must turn into upload-ready shares, and
// malformed entries must be skipped without losing the rest.

import 'package:landir_app/src/platform/share_intent.dart';
import 'package:test/test.dart';

void main() {
  group('incomingSharesFromPayload', () {
    test('file share carries the cached path and the resolved filename', () {
      final shares = incomingSharesFromPayload(
          '[{"path":"/cache/shared/123_backup.zip","filename":"backup.zip"}]');
      expect(shares, hasLength(1));
      expect(shares.first.isText, isFalse);
      expect(shares.first.filename, 'backup.zip');
      expect(shares.first.filePath, '/cache/shared/123_backup.zip');
      expect(shares.first.text, isNull);
    });

    test('text share becomes a text upload', () {
      final shares =
          incomingSharesFromPayload('[{"text":"https://192.168.1.5:8000/"}]');
      expect(shares, hasLength(1));
      expect(shares.first.isText, isTrue);
      expect(shares.first.filename, 'shared.txt');
      expect(shares.first.text, 'https://192.168.1.5:8000/');
    });

    test('mixed batches keep their order', () {
      final shares = incomingSharesFromPayload(
          '[{"path":"/cache/a.apk","filename":"a.apk"},'
          '{"text":"hello"},'
          '{"path":"/cache/b.zip","filename":"b.zip"}]');
      expect(shares.map((s) => s.filename), ['a.apk', 'shared.txt', 'b.zip']);
    });

    test('whitespace-only text shares are dropped', () {
      expect(incomingSharesFromPayload('[{"text":"   \\t "}]'), isEmpty);
    });

    test('malformed entries are skipped, healthy ones survive', () {
      final payload = '[null, 7, "str", {}, '
          '{"path":"/cache/good.zip","filename":"good.zip"},'
          '{"path":"/cache/no-name"},'
          '{"filename":"no-path"},'
          '{"path":"","filename":"empty.zip"},'
          '{"path":123,"filename":"num.zip"}]';
      final shares = incomingSharesFromPayload(payload);
      expect(shares, hasLength(1));
      expect(shares.first.filename, 'good.zip');
    });

    test('a non-array payload yields no shares', () {
      expect(incomingSharesFromPayload('{"path":"/cache/x.zip"}'), isEmpty);
    });
  });
}
