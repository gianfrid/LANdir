// Minimal runner: starts the Landir core server on a port and prints the URL.
// Used for live cross-checks against the Python reference probes.

import 'dart:io';

import 'package:landir_app/src/core/file_sink.dart';
import 'package:landir_app/src/core/server.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8000;
  final dir = args.length > 1 ? args[1] : '/tmp/landir_dart_uploads';
  final insecure = args.contains('--insecure');
  final token = insecure ? null : 'livetest';
  final config = ServerConfig(
    port: port,
    uploadDir: dir,
    insecure: insecure,
    secretToken: token,
  );
  final server = LandirServer(config, DirectoryFileSink(dir));
  await server.start();
  print('PORT=${server.boundPort}');
  print('READY');
  // Keep running until killed
  await ProcessSignal.sigterm.watch().first;
}
