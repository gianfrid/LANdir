// Provider-level tests for the user-selectable Save directory (desktop
// only): where received files are stored. Null means the default
// Documents directory.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/platform/documents_sink.dart';
import 'package:landir_app/src/providers/server_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ServerController notifierOf(ProviderContainer container) =>
      container.read(serverControllerProvider.notifier);

  test('save dir defaults to null (Documents directory)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(serverControllerProvider).saveDir, isNull);
  });

  test('save dir is selectable while stopped, empty string clears it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = notifierOf(container);

    notifier.setSaveDir('/home/me/inbox');
    expect(container.read(serverControllerProvider).saveDir, '/home/me/inbox');

    notifier.setSaveDir(''); // empty clears back to the default
    expect(container.read(serverControllerProvider).saveDir, isNull);
  });

  test('setSaveDir is ignored while the server is running', () {
    final container = ProviderContainer(
      overrides: [serverControllerProvider.overrideWith(_Running.new)],
    );
    addTearDown(container.dispose);
    notifierOf(container).setSaveDir('/tmp/elsewhere');
    expect(container.read(serverControllerProvider).saveDir, isNull);
  });

  test('setSaveDir persists the choice across app restarts', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    notifierOf(container).setSaveDir('/home/me/inbox');
    await Future<void>.delayed(Duration.zero); // flush the unawaited write

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('save_dir'), '/home/me/inbox');

    // Clearing the choice removes the stored value entirely.
    notifierOf(container).setSaveDir(null);
    await Future<void>.delayed(Duration.zero);
    expect(prefs.getString('save_dir'), isNull);
  });

  test('loadPersistedSettings restores a saved choice', () async {
    SharedPreferences.setMockInitialValues({'save_dir': '/home/me/inbox'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await notifierOf(container).loadPersistedSettings();
    expect(container.read(serverControllerProvider).saveDir, '/home/me/inbox');
  });

  test('loadPersistedSettings ignores an empty stored value', () async {
    SharedPreferences.setMockInitialValues({'save_dir': ''});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await notifierOf(container).loadPersistedSettings();
    expect(container.read(serverControllerProvider).saveDir, isNull);
  });

  test('stop() keeps the save dir choice for the next start', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    notifierOf(container).setSaveDir('/home/me/inbox');
    // A regression to `const ServerState()` here would drop the choice.
    expect(notifierOf(container).stop(), completes);
    final state = container.read(serverControllerProvider);
    expect(state.running, isFalse);
    expect(state.saveDir, '/home/me/inbox');
  });

  test('the file sink targets a persisted save dir on desktop', () async {
    if (!canChooseSaveDir) return; // choice only exists on desktop
    final dir = await Directory.systemTemp.createTemp('landir-save');
    addTearDown(() => dir.deleteSync(recursive: true));
    SharedPreferences.setMockInitialValues({'save_dir': dir.path});

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final sink = await container.read(fileSinkProvider.future);
    expect(sink, isA<DocumentsFileSink>());
    expect((sink as DirectoryFileSink).rootDir, dir.path);
  }, skip: !canChooseSaveDir ? 'desktop only' : false);
}

/// A controller that reports a running server without binding anything.
class _Running extends ServerController {
  @override
  ServerState build() => const ServerState(running: true, port: 4242);
}
