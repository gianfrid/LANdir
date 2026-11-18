// Host view: the main screen of the Landir app in host role.
// Shows the QR code, URL, and start/stop controls.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/server.dart' show ServerConfig;
import '../providers/server_provider.dart';

class HostView extends ConsumerStatefulWidget {
  const HostView({super.key});

  @override
  ConsumerState<HostView> createState() => _HostViewState();
}

class _HostViewState extends ConsumerState<HostView> {
  @override
  void initState() {
    super.initState();
    // Restore the persisted port choice once (mirrors the client view,
    // which loads its registry on creation in the same way).
    ref.read(serverControllerProvider.notifier).loadPersistedPort();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(serverControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('LANdir')),
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
            const Text('Port'),
            const SizedBox(width: 12),
            SizedBox(
              width: 100,
              child: _PortField(port: state.requestedPort),
            ),
            const SizedBox(width: 8),
            const Text('0 = random',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 16),
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

/// Numeric port input for the idle host view. Commits valid drafts
/// (0-65535) to the server controller; an invalid or empty draft is
/// flagged and discarded in favor of the committed port on unfocus, so
/// the field never silently disagrees with the controller.
class _PortField extends ConsumerStatefulWidget {
  const _PortField({required this.port});

  final int port;

  @override
  ConsumerState<_PortField> createState() => _PortFieldState();
}

class _PortFieldState extends ConsumerState<_PortField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.port.toString());
    _focusNode = FocusNode()..addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus && _invalid) {
      // Discard the invalid draft; reshow the committed port.
      _controller.text = widget.port.toString();
      setState(() => _invalid = false);
    }
  }

  @override
  void didUpdateWidget(covariant _PortField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync external changes (e.g. reset after stop) without clobbering
    // what the user is currently typing.
    if (int.tryParse(_controller.text) != widget.port) {
      _controller.text = widget.port.toString();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      maxLength: 5,
      decoration: InputDecoration(
        counterText: '',
        isDense: true,
        border: const OutlineInputBorder(),
        errorText: _invalid ? '0 - 65535' : null,
      ),
      onChanged: (value) {
        final port = int.tryParse(value);
        if (port != null && ServerConfig.isValidPort(port)) {
          ref.read(serverControllerProvider.notifier).setPort(port);
          if (_invalid) setState(() => _invalid = false);
        } else {
          setState(() => _invalid = true);
        }
      },
    );
  }
}
