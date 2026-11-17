// File browser: lists a server's /files, upload via file picker, download.

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/local_downloads.dart';
import '../platform/save_download.dart';
import '../providers/client_provider.dart';
import '../providers/local_downloads_provider.dart';

class FileBrowserView extends ConsumerWidget {
  const FileBrowserView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The browsed server was deselected (deleted, or dropped after a 404):
    // leave this now-serverless browser. Keyed on the `current` transition
    // so it does not depend on listener ordering.
    ref.listen(clientControllerProvider, (prev, next) {
      if (shouldLeaveBrowser(prev, next) && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });

    final state = ref.watch(clientControllerProvider);
    final server = state.current;

    return Scaffold(
      appBar: AppBar(
        title: Text(server?.name ?? 'Files'),
        leading: state.currentPath.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () =>
                    ref.read(clientControllerProvider.notifier).navigateUp(),
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.read(clientControllerProvider.notifier).refresh(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (state.currentPath.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => ref
                      .read(clientControllerProvider.notifier)
                      .navigateUp(),
                  icon: const Icon(Icons.arrow_upward, size: 16),
                  label: Text('/${state.currentPath}'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.grey,
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
          if (state.error != null)
            Card(
              color: Colors.red.shade100,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(state.error!,
                    style: const TextStyle(color: Colors.black87)),
              ),
            ),
          if (state.statusMessage != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(state.statusMessage!,
                  style: const TextStyle(color: Colors.grey)),
            ),
          if (state.loading)
            const LinearProgressIndicator()
          else
            const SizedBox(height: 4),
          Expanded(
            child: state.files.isEmpty
                ? const Center(child: Text('No files on this server.'))
                : ListView.builder(
                    itemCount: state.files.length + (state.currentPath.isNotEmpty ? 1 : 0),
                    itemBuilder: (context, i) {
                      // ".." row at the top when inside a folder
                      if (state.currentPath.isNotEmpty && i == 0) {
                        return ListTile(
                          leading: const Icon(Icons.arrow_upward),
                          title: const Text('..'),
                          onTap: () => ref
                              .read(clientControllerProvider.notifier)
                              .navigateUp(),
                        );
                      }
                      final f = state.files[state.currentPath.isNotEmpty ? i - 1 : i];
                      return ListTile(
                        leading: Icon(
                            f.isDir ? Icons.folder : Icons.insert_drive_file),
                        title: Text(f.name),
                        subtitle: f.isDir
                            ? null
                            : Text('${_fmtSize(f.size)} • '
                                '${DateTime.fromMillisecondsSinceEpoch(
                                  (f.mtime * 1000).toInt()).toLocal()}'),
                        onTap: f.isDir
                            ? () => ref
                                .read(clientControllerProvider.notifier)
                                .navigateInto(f.name)
                            : () => _download(context, ref, f.name),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _pickAndUpload(context, ref),
        icon: const Icon(Icons.upload_file),
        label: const Text('Upload'),
      ),
    );
  }

  Future<void> _pickAndUpload(BuildContext context, WidgetRef ref) async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    final notifier = ref.read(clientControllerProvider.notifier);
    var ok = 0;
    for (final file in files) {
      final Uint8List bytes;
      if (file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      } else {
        bytes = await file.xFile.readAsBytes();
      }
      if (await notifier.uploadFile(file.name, bytes)) ok++;
    }
    if (context.mounted) {
      final state = ref.read(clientControllerProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(state.error != null
              ? 'Upload failed: ${state.error}'
              : ok == files.length
                  ? 'Uploaded $ok file(s)'
                  : 'Uploaded $ok of ${files.length} file(s)'),
        ),
      );
    }
  }

  Future<void> _download(BuildContext context, WidgetRef ref, String name) async {
    // Send the full path relative to the server root so files inside
    // folders resolve; save locally under the bare file name.
    final state = ref.read(clientControllerProvider);
    final relPath =
        state.currentPath.isEmpty ? name : '${state.currentPath}/$name';
    final bytes = await ref
        .read(clientControllerProvider.notifier)
        .downloadFile(relPath);
    if (bytes != null && context.mounted) {
      var onCollision = CollisionAction.rename;
      if (await downloadExists(name)) {
        if (!context.mounted) return;
        final choice = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('$name already exists'),
            content: const Text(
              'Replace the existing file, or save this one with a '
              'numbered name?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Rename'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Replace'),
              ),
            ],
          ),
        );
        if (choice == null) return; // cancelled
        onCollision =
            choice ? CollisionAction.overwrite : CollisionAction.rename;
      }
      try {
        final saved = await saveDownload(name, bytes, onCollision: onCollision);
        await recordDownload(saved.name);
        ref.invalidate(localDownloadsProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved ${saved.name} to ${saved.where}'),
            action: SnackBarAction(
              label: 'Open',
              onPressed: () async {
                final ok = await openDownloadedFile(saved.name);
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('No app can open ${saved.name}')),
                  );
                }
              },
            ),
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Downloaded but save failed: $e')),
        );
      }
    }
  }

  String _fmtSize(int n) {
    if (n < 1024) return '$n B';
    const units = ['KB', 'MB', 'GB'];
    var i = -1;
    double v = n.toDouble();
    do {
      v /= 1024;
      i++;
    } while (v >= 1024 && i < units.length - 1);
    return '${v.toStringAsFixed(1)} ${units[i]}';
  }
}
