// Landir app entry point. Adaptive layout: side-by-side Host/Client on
// wide (desktop) windows, bottom-nav tabs on narrow (phone) screens.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'src/platform/share_intent.dart';
import 'src/providers/client_provider.dart';
import 'src/views/client_view.dart';
import 'src/views/downloads_view.dart';
import 'src/views/host_view.dart';

const double _wideBreakpoint = 600.0;

void main() {
  // Never show a black screen: render framework errors as a readable message.
  ErrorWidget.builder = (details) => Material(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Something went wrong:\n${details.exception}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ),
      );
  runApp(const ProviderScope(child: LandirApp()));
}

class LandirApp extends StatelessWidget {
  const LandirApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Landir',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const _AdaptiveHome(),
    );
  }
}

class _AdaptiveHome extends ConsumerStatefulWidget {
  const _AdaptiveHome();

  @override
  ConsumerState<_AdaptiveHome> createState() => _AdaptiveHomeState();
}

class _AdaptiveHomeState extends ConsumerState<_AdaptiveHome> {
  // Default to the Client tab on phones: most sessions are "upload to the
  // server I was connected to", and loadPersisted() reconnects automatically.
  int _tab = 1;
  StreamSubscription<List<SharedMediaFile>>? _shareSub;

  @override
  void initState() {
    super.initState();
    // Shares arriving while the app is running.
    _shareSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_handleSharedMedia);
    // Share that launched the app from a closed state.
    ReceiveSharingIntent.instance.getInitialMedia().then((media) {
      ReceiveSharingIntent.instance.reset();
      _handleSharedMedia(media);
    });
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    super.dispose();
  }

  void _handleSharedMedia(List<SharedMediaFile> media) {
    final shares = incomingSharesFromMedia(media);
    if (shares.isEmpty) return;
    ref.read(clientControllerProvider.notifier).receiveShares(shares);
    // Bring the client tab forward so the user sees the upload happen.
    setState(() => _tab = 1);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > _wideBreakpoint) {
          // Desktop admin: all three panels side by side
          return Scaffold(
            body: const Row(
              children: [
                Expanded(child: HostView()),
                VerticalDivider(width: 1),
                Expanded(child: ClientView()),
                VerticalDivider(width: 1),
                Expanded(child: DownloadsView()),
              ],
            ),
          );
        }
        // Phone: tabs
        return Scaffold(
          body: IndexedStack(
            index: _tab,
            children: const [HostView(), ClientView(), DownloadsView()],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.dns), label: 'Host'),
              NavigationDestination(
                  icon: Icon(Icons.devices), label: 'Client'),
              NavigationDestination(
                  icon: Icon(Icons.download), label: 'Downloads'),
            ],
          ),
        );
      },
    );
  }
}
