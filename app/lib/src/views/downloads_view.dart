// Downloads tab: lists files this app has downloaded, tap to re-open.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/local_downloads.dart';
import '../platform/save_download.dart';
import '../providers/local_downloads_provider.dart';

class DownloadsView extends ConsumerWidget {
  const DownloadsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadsAsync = ref.watch(localDownloadsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(localDownloadsProvider),
          ),
        ],
      ),
      body: downloadsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (items) => items.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Nothing downloaded yet.\nFiles you download from a '
                    'server appear here.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final d = items[i];
                  final date = DateTime.fromMillisecondsSinceEpoch(d.timestamp)
                      .toLocal();
                  return ListTile(
                    leading: const Icon(Icons.download_done),
                    title: Text(d.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text('$date'),
                    trailing: canOpenFiles
                        ? const Icon(Icons.open_in_new)
                        : null,
                    onTap: canOpenFiles
                        ? () => openDownloadedFile(d.name)
                        : null,
                    onLongPress: () async {
                      await forgetDownload(d.name);
                      ref.invalidate(localDownloadsProvider);
                    },
                  );
                },
              ),
      ),
    );
  }
}
