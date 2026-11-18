// LANdir app entry point. Adaptive layout: on wide (desktop) windows a
// segmented Host/Client toggle with a Downloads side panel; on narrow
// (phone) screens, bottom-nav tabs.

import 'dart:async';
import 'dart:io';

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
      title: 'LANdir',
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
  // Desktop role toggle: 0 = Host, 1 = Client.
  int _role = 0;
  bool _wide = false;
  StreamSubscription<List<SharedMediaFile>>? _shareSub;

  @override
  void initState() {
    super.initState();
    // Share intents only exist on Android/iOS; the plugin has no desktop
    // implementation and throws MissingPluginException there.
    if (!Platform.isAndroid && !Platform.isIOS) return;
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
    // Bring the client forward so the user sees the upload happen.
    setState(() {
      if (_wide) {
        _role = 1;
      } else {
        _tab = 1;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _wide = constraints.maxWidth > _wideBreakpoint;
        if (_wide) {
          // Desktop: Host/Client behind a segmented toggle, Downloads beside.
          return Scaffold(
            body: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(
                                value: 0,
                                icon: Icon(Icons.dns),
                                label: Text('Host')),
                            ButtonSegment(
                                value: 1,
                                icon: Icon(Icons.devices),
                                label: Text('Client')),
                          ],
                          selected: {_role},
                          onSelectionChanged: (selected) =>
                              setState(() => _role = selected.first),
                        ),
                      ),
                      Expanded(
                        child: IndexedStack(
                          index: _role,
                          children: const [HostView(), ClientView()],
                        ),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                const Expanded(child: DownloadsView()),
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
