// Host view: the main screen of the Landir app in host role.
// Shows the QR code, URL, and start/stop controls.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../providers/server_provider.dart';

class HostView extends ConsumerWidget {
  const HostView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(serverControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Landir')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (Platform.isIOS && state.running) ...[
              Card(
                color: Colors.orange.shade100,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'iOS keeps the server running only while this app is '
                    'in the foreground. Do not leave this screen.',
                    style: TextStyle(color: Colors.black87),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (state.error != null) ...[
              Card(
                color: Colors.red.shade100,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('Error: ${state.error}',
                      style: const TextStyle(color: Colors.black87)),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Expanded(
              child: state.running && state.url != null
                  ? _runningView(context, ref, state)
                  : _idleView(context, ref, state),
            ),
          ],
        ),
      ),
    );
  }

  Widget _idleView(BuildContext context, WidgetRef ref, ServerState state) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.upload_file, size: 80, color: Colors.grey),
        const SizedBox(height: 16),
        const Text(
          'Start the server to receive files from any device on the network.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Secret URL mode'),
            Switch(
              value: !state.insecure,
              onChanged: (_) =>
                  ref.read(serverControllerProvider.notifier).toggleInsecure(),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () =>
              ref.read(serverControllerProvider.notifier).start(),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start server'),
        ),
      ],
    );
  }

  Widget _runningView(BuildContext context, WidgetRef ref, ServerState state) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        QrImageView(
          data: state.url!,
          version: QrVersions.auto,
          size: 220,
          backgroundColor: Colors.white,
        ),
        const SizedBox(height: 16),
        SelectableText(
          state.url!,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        if (state.hotspotSsid != null) ...[
          const SizedBox(height: 8),
          Text('Hotspot: ${state.hotspotSsid}',
              style: const TextStyle(color: Colors.grey)),
        ],
        const SizedBox(height: 8),
        Text('Port ${state.port} • ${state.insecure ? 'insecure' : 'secret'} mode',
            style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () =>
              ref.read(serverControllerProvider.notifier).stop(),
          icon: const Icon(Icons.stop),
          label: const Text('Stop server'),
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
        ),
      ],
    );
  }
}
