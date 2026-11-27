// Provider-level test for the host-view "Add files" entry point:
// addLocalFiles must fail cleanly (never throw, never write) while the
// server is not running.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landir_app/src/providers/server_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('addLocalFiles while stopped reports a batch-level failure', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(serverControllerProvider.notifier);

    // PlatformFile is abstract, so exercise the guard with an empty batch —
    // it must fail before reading any file, never throw, never write.
    final result = await notifier.addLocalFiles(const []);
    expect(result.ok, 0);
    expect(result.failures, ['server is not running']);
  });

  test('addLocalFolder while stopped reports a batch-level failure',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(serverControllerProvider.notifier);

    final result = await notifier.addLocalFolder(Uri.parse('file:///tmp/x'));
    expect(result.ok, 0);
    expect(result.failures, ['server is not running']);
  });
}
