// Client view: list of saved Landir servers, QR scan to add, and entry
// to the file browser for the selected server.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/client_provider.dart';
import 'file_browser_view.dart';
import 'qr_scan_view.dart';

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

    // Surface a server that was dropped because it answered 404.
    ref.listen(clientControllerProvider, (prev, next) {
      final url = next.removedServerUrl;
      if (url == null || url == prev?.removedServerUrl) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(
        content: Text('Server $url no longer exists (404). It was removed.'),
      ));
      ref.read(clientControllerProvider.notifier).acknowledgeRemovedServer();
    });

    // Warn before adding a server whose address is not on the LAN: Landir
    // is LAN-only, so a public address usually means a mistyped or
    // malicious QR code. Uploads would send file bytes to that host.
    ref.listen(clientControllerProvider, (prev, next) {
      final pending = next.pendingNonLanServer;
      if (pending == null || pending.baseUrl == prev?.pendingNonLanServer?.baseUrl) {
        return;
      }
      _confirmNonLanServer(context, ref, pending);
    });

    // A rescan presented a different host key for an already-pinned
    // (host, port): block and ask for explicit re-pairing (Signal
    // safety-number pattern). Never silently adopt the new key.
    ref.listen(clientControllerProvider, (prev, next) {
      final conflict = next.pendingKeyConflict;
      if (conflict == null ||
          conflict.scanned.baseUrl == prev?.pendingKeyConflict?.scanned.baseUrl) {
        return;
      }
      _confirmRekey(context, ref, conflict);
    });

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
                  'to a LANdir server.',
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
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Pairing badge (design 001, M5): pinned key = sealed
                      // transport; keyless host = documented plaintext.
                      _PairingBadge(paired: server.hostKey != null),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => ref
                            .read(clientControllerProvider.notifier)
                            .removeServer(server.baseUrl),
                      ),
                    ],
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
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanView()),
    );
    if (code != null && context.mounted) {
      ref.read(clientControllerProvider.notifier).addServer(code);
    }
  }

  Future<void> _confirmNonLanServer(
    BuildContext context,
    WidgetRef ref,
    SavedServer server,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.public),
        title: const Text('Address outside the local network'),
        content: Text(
          '${server.baseUrl} is not a private (LAN) address.\n\n'
          'LANdir is designed for local networks only. Adding a public '
          'address is unusual: double-check that the QR code or URL is '
          'what you intended — anything you upload would be sent to it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add anyway'),
          ),
        ],
      ),
    );
    final notifier = ref.read(clientControllerProvider.notifier);
    if (confirmed == true) {
      notifier.confirmPendingNonLanServer();
    } else {
      notifier.cancelPendingNonLanServer();
    }
  }

  /// Re-pair dialog for a changed host key: explains that the server at
  /// that address presented a different key than the pinned one, and only
  /// re-pairs on explicit confirmation.
  Future<void> _confirmRekey(
    BuildContext context,
    WidgetRef ref,
    ({SavedServer existing, SavedServer scanned}) conflict,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.vpn_key_off, color: Colors.orange),
        title: const Text('Server key changed'),
        content: Text(
          'The server at ${conflict.scanned.name} presented a different '
          'security key — or none at all — than the one pinned for this '
          'address.\n\n'
          'This can happen when the host app was reinstalled. If you did '
          'not expect it, someone may be impersonating the server.\n\n'
          'Re-pair and replace the pinned key?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep old key'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Re-pair'),
          ),
        ],
      ),
    );
    final notifier = ref.read(clientControllerProvider.notifier);
    if (confirmed == true) {
      notifier.confirmRekey();
    } else {
      notifier.cancelRekey();
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

/// Encrypted / Not encrypted chip shown next to each saved server
/// (design 001, M5): a pinned host key means sealed transport, a keyless
/// host stays on the documented plaintext contract.
class _PairingBadge extends StatelessWidget {
  const _PairingBadge({required this.paired});

  final bool paired;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          paired ? 'Encrypted (paired host key)' : 'Not encrypted (no key)',
      child: Chip(
        avatar: Icon(
          paired ? Icons.lock : Icons.lock_open,
          size: 16,
          color: paired ? Colors.green : Colors.orange,
        ),
        label: Text(
          paired ? 'Encrypted' : 'Not encrypted',
          style: const TextStyle(fontSize: 12),
        ),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
