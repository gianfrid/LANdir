// Provider-level test for client directory navigation logic.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/core/server.dart';
import 'package:landir_app/src/providers/client_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  late String tmpDir;
  late LandirServer server;
  late int port;
  late ProviderContainer container;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('landir_nav_').path;
    Directory('$tmpDir/reports/2025').createSync(recursive: true);
    File('$tmpDir/reports/q3.txt').writeAsStringSync('q3');
    File('$tmpDir/reports/2025/q4.txt').writeAsStringSync('q4');
    File('$tmpDir/top.txt').writeAsStringSync('top');
    server = LandirServer(
      ServerConfig(port: 0, uploadDir: tmpDir, insecure: true),
      DirectoryFileSink(tmpDir),
    );
    await server.start();
    port = server.boundPort;
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await server.stop();
    Directory(tmpDir).deleteSync(recursive: true);
  });

  test('navigateInto / navigateUp walk the directory tree', () async {
    // Keep the autoDispose provider alive for the duration of the test.
    final sub = container.listen(clientControllerProvider, (prev, next) {});
    addTearDown(sub.close);
    final notifier = container.read(clientControllerProvider.notifier);
    await notifier.selectServer(
        SavedServer(name: 'test', baseUrl: 'http://127.0.0.1:$port/'));
    expect(container.read(clientControllerProvider).currentPath, '');
    expect(container.read(clientControllerProvider).files.map((f) => f.name),
        containsAll(['top.txt', 'reports']));

    await notifier.navigateInto('reports');
    var state = container.read(clientControllerProvider);
    expect(state.currentPath, 'reports');
    expect(state.files.map((f) => f.name), containsAll(['q3.txt', '2025']));

    await notifier.navigateInto('2025');
    state = container.read(clientControllerProvider);
    expect(state.currentPath, 'reports/2025');
    expect(state.files.map((f) => f.name), contains('q4.txt'));

    await notifier.navigateUp();
    state = container.read(clientControllerProvider);
    expect(state.currentPath, 'reports');

    await notifier.navigateUp();
    state = container.read(clientControllerProvider);
    expect(state.currentPath, '');
    expect(state.files.map((f) => f.name), contains('top.txt'));

    // navigateUp at root stays at root
    await notifier.navigateUp();
    expect(container.read(clientControllerProvider).currentPath, '');
  });
}
