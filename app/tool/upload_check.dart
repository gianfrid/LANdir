// One-shot: upload a file to a Landir server at the given base URL using
// LandirClient, then list and download to prove the round trip.
// Usage: dart run tool/upload_check.dart <baseUrl>
import 'dart:convert';
import 'dart:io';

import 'package:landir_app/src/core/client.dart';

Future<void> main(List<String> args) async {
  final baseUrl = args[0];
  final client = LandirClient(baseUrl);
  final content = utf8.encode('uploaded from dart client at ${DateTime.now()}');
  final ok = await client.uploadFile('dartcheck.txt', content);
  print('upload ok: $ok');
  final files = await client.listFiles();
  print('files: ${files.map((f) => f.name).toList()}');
  final dl = await client.downloadFile('dartcheck.txt');
  print('download matches: ${utf8.decode(dl) == utf8.decode(content)}');
  client.close();
  exit(ok ? 0 : 1);
}
