// Tests for share-sheet intake: filename derivation and the pure model.

import 'package:landir_app/src/core/share.dart';
import 'package:test/test.dart';

void main() {
  group('filenameFromSharePath', () {
    test('plain unix path', () {
      expect(filenameFromSharePath('/cache/shared/report.pdf'), 'report.pdf');
    });

    test('windows-style path', () {
      expect(filenameFromSharePath('C:\\Users\\dev\\notes.txt'), 'notes.txt');
    });

    test('trailing slash yields last component', () {
      expect(filenameFromSharePath('/cache/shared/photo.jpg/'), 'photo.jpg');
    });

    test('empty path falls back to generic name', () {
      expect(filenameFromSharePath(''), 'shared-file');
    });

    test('bare filename passes through', () {
      expect(filenameFromSharePath('image.png'), 'image.png');
    });
  });

  group('IncomingShare', () {
    test('file share keeps filename and path, is not text', () {
      const share = IncomingShare.file(
          filename: 'a.png', filePath: '/cache/a.png');
      expect(share.filename, 'a.png');
      expect(share.filePath, '/cache/a.png');
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
