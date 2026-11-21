// Tests for the share-intent upload flow in ClientController, against a
// live LANdirServer (same pattern as client_test.dart).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/core/server.dart';
import 'package:landir_app/src/core/share.dart';
import 'package:landir_app/src/providers/client_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

void main() {
  late String tmpDir; // server upload directory
  late String srcDir; // where test "shared" files live
  late LANdirServer server;
  late ProviderContainer container;
  late ProviderSubscription<ClientState> keepAlive;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = Directory.systemTemp.createTempSync('landir_share_up_').path;
    srcDir = Directory.systemTemp.createTempSync('landir_share_src_').path;
    final config = ServerConfig(
      port: 0,
      uploadDir: tmpDir,
      insecure: true,
    );
    server = LANdirServer(config, DirectoryFileSink(tmpDir));
    await server.start();
    container = ProviderContainer();
    // clientControllerProvider is auto-dispose; keep it alive for the test.
    keepAlive = container.listen(clientControllerProvider, (_, _) {});
  });

  tearDown(() async {
    keepAlive.close();
    container.dispose();
    await server.stop();
    Directory(tmpDir).deleteSync(recursive: true);
    Directory(srcDir).deleteSync(recursive: true);
  });

  SavedServer testServer() =>
      SavedServer(name: 'test', baseUrl: 'http://127.0.0.1:${server.boundPort}/');

  /// Names present in the server's upload directory.
  List<String> uploaded() =>
      Directory(tmpDir).listSync().map((e) => e.path.split('/').last).toList();

  test('share with no server selected is held as pending', () async {
    final controller = container.read(clientControllerProvider.notifier);
    await controller.receiveShares([
      const IncomingShare.file(filename: 'a.txt', filePath: '/tmp/a.txt'),
    ]);
    final state = container.read(clientControllerProvider);
    expect(state.pendingShares, hasLength(1));
    expect(state.current, isNull);
    expect(uploaded(), isEmpty);
  });

  test('share with a current server uploads immediately', () async {
    final controller = container.read(clientControllerProvider.notifier);
    final file = File('$srcDir/share-src.txt');
    await file.writeAsString('shared content');

    await controller.selectServer(testServer());
    await controller.receiveShares([
      IncomingShare.file(filename: 'a.txt', filePath: file.path),
    ]);

    final state = container.read(clientControllerProvider);
    expect(state.pendingShares, isEmpty);
    expect(state.error, isNull);
    expect(uploaded(), contains('a.txt'));
    expect(await File('$tmpDir/a.txt').readAsString(), 'shared content');
  });

  test('pending shares flush when a server is selected afterwards', () async {
    final controller = container.read(clientControllerProvider.notifier);
    final file = File('$srcDir/late-src.txt');
    await file.writeAsString('late content');

    await controller.receiveShares([
      IncomingShare.file(filename: 'late.txt', filePath: file.path),
      const IncomingShare.text(text: 'a link'),
    ]);
    expect(
        container.read(clientControllerProvider).pendingShares, hasLength(2));

    await controller.selectServer(testServer());

    final state = container.read(clientControllerProvider);
    expect(state.pendingShares, isEmpty);
    expect(uploaded(), containsAll(['late.txt', 'shared.txt']));
    expect(await File('$tmpDir/shared.txt').readAsString(), 'a link');
    expect(await File('$tmpDir/late.txt').readAsString(), 'late content');
  });

  test('text share uploads as shared.txt with utf-8 content', () async {
    final controller = container.read(clientControllerProvider.notifier);
    await controller.selectServer(testServer());
    await controller.receiveShares([const IncomingShare.text(text: 'héllo ☕')]);
    expect(await File('$tmpDir/shared.txt').readAsString(encoding: utf8),
        'héllo ☕');
  });

  test('an unreadable share does not block the rest of the batch', () async {
    final controller = container.read(clientControllerProvider.notifier);
    await controller.selectServer(testServer());
    await controller.receiveShares([
      const IncomingShare.file(
          filename: 'gone.txt', filePath: '/nonexistent/gone.txt'),
      const IncomingShare.text(text: 'still here'),
    ]);
    final state = container.read(clientControllerProvider);
    expect(state.error, contains('1 of 2'));
    expect(await File('$tmpDir/shared.txt').readAsString(), 'still here');
    expect(uploaded(), isNot(contains('gone.txt')));
  });
}
