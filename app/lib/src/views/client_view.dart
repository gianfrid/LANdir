// Client view: list of saved Landir servers, QR scan to add, and entry
// to the file browser for the selected server.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../providers/client_provider.dart';
import 'file_browser_view.dart';

class ClientView extends ConsumerStatefulWidget {
  const ClientView({super.key});

  @override
  ConsumerState<ClientView> createState() => _ClientViewState();
}

class _ClientViewState extends ConsumerState<ClientView> {
  @override
  void initState() {
    super.initState();
    // Load persisted server registry once
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(clientControllerProvider.notifier).loadPersisted();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final state = ref.watch(clientControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Client'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => _scanQr(context, ref),
            tooltip: 'Scan server QR code',
          ),
          IconButton(
            icon: const Icon(Icons.add_link),
            onPressed: () => _addManually(context, ref),
            tooltip: 'Add server by URL',
          ),
        ],
      ),
      body: state.servers.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No servers yet.\nScan a QR code or add a URL to connect '
                  'to a Landir server.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: state.servers.length,
              itemBuilder: (context, i) {
                final server = state.servers[i];
                final isCurrent = state.current?.baseUrl == server.baseUrl;
                return ListTile(
                  leading: Icon(isCurrent
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked),
                  title: Text(server.name),
                  subtitle: Text(server.baseUrl),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => ref
                        .read(clientControllerProvider.notifier)
                        .removeServer(server.baseUrl),
                  ),
                  onTap: () {
                    ref
                        .read(clientControllerProvider.notifier)
                        .selectServer(server);
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const FileBrowserView(),
                    ));
                  },
                );
              },
            ),
    );
  }

  Future<void> _scanQr(BuildContext context, WidgetRef ref) async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Scan server QR')),
        body: MobileScanner(
          onDetect: (capture) {
            final raw = capture.barcodes.first.rawValue;
            if (raw != null) Navigator.of(context).pop(raw);
          },
        ),
      ),
    ));
    if (code != null && context.mounted) {
      ref.read(clientControllerProvider.notifier).addServer(code);
    }
  }

  void _addManually(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add server'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'http://192.168.1.5:8000/token/',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                ref
                    .read(clientControllerProvider.notifier)
                    .addServer(controller.text);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}
