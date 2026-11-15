// Riverpod provider for the local downloads list.

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../platform/local_downloads.dart';

part 'local_downloads_provider.g.dart';

@riverpod
Future<List<LocalDownload>> localDownloads(Ref ref) async {
  return listLocalDownloads();
}
