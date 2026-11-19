// Tests for the share-intake model: the pure IncomingShare contract.
// Filename derivation from paths lives in the platform layer now
// (test/platform/share_intent_test.dart); the model only carries decisions.

import 'package:landir_app/src/core/share.dart';
import 'package:test/test.dart';

void main() {
  group('IncomingShare', () {
    test('file share keeps filename and path, is not text', () {
      const share = IncomingShare.file(
          filename: 'a.zip', filePath: '/cache/shared/a.zip');
      expect(share.filename, 'a.zip');
      expect(share.filePath, '/cache/shared/a.zip');
      expect(share.text, isNull);
      expect(share.isText, isFalse);
    });

    test('text share uploads as shared.txt', () {
      const share = IncomingShare.text(text: 'hello world');
      expect(share.filename, 'shared.txt');
      expect(share.text, 'hello world');
      expect(share.filePath, isNull);
      expect(share.isText, isTrue);
    });
  });
}
