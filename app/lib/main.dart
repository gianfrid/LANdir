// LANdir app entry point. Adaptive layout: on wide (desktop) windows a
// segmented Host/Client toggle with a Downloads side panel; on narrow
// (phone) screens, bottom-nav tabs.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/platform/share_intent.dart';
import 'src/providers/client_provider.dart';
import 'src/providers/local_downloads_provider.dart';
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
  runApp(const ProviderScope(child: LANdirApp()));
}

class LANdirApp extends StatelessWidget {
  const LANdirApp({super.key});

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
  // When true (default) the desktop Downloads frame hides itself while
  // the download list is empty; the toolbar toggle pins it open.
  bool _autoHideDownloads = true;
  StreamSubscription<String>? _shareSub;

  static const MethodChannel _shareMethods =
      MethodChannel('landir/share_intent');
  static const EventChannel _shareEvents =
      EventChannel('landir/share_intent/events');

  @override
  void initState() {
    super.initState();
    // The share-intake channels exist only on Android; elsewhere they
    // would throw MissingPluginException.
    if (!Platform.isAndroid) return;
    // Shares arriving while the app is running.
    _shareSub = _shareEvents
        .receiveBroadcastStream()
        .map((payload) => payload as String)
        .listen(_handleSharePayload);
    // Share that launched the app from a closed state.
    _shareMethods.invokeMethod<String>('getInitialShares').then((payload) {
      if (payload != null) _handleSharePayload(payload);
    });
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    super.dispose();
  }

  void _handleSharePayload(String payload) {
    final shares = incomingSharesFromPayload(payload);
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
          // Desktop: Host/Client behind a segmented toggle, Downloads beside
          // unless it would be an empty frame that just eats width.
          final downloadsVisible = !_autoHideDownloads ||
              ref
                  .watch(localDownloadsProvider)
                  .maybeWhen(data: (items) => items.isNotEmpty, orElse: () => false);
          return Scaffold(
            body: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            SegmentedButton<int>(
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
                            const Spacer(),
                            IconButton(
                              // Selected = pinned visible; outlined =
                              // auto-hides once the list is empty.
                              isSelected: !_autoHideDownloads,
                              selectedIcon: const Icon(Icons.view_sidebar),
                              icon: const Icon(Icons.view_sidebar_outlined),
                              tooltip: _autoHideDownloads
                                  ? 'Keep the downloads panel always visible'
                                  : 'Auto-hide the downloads panel when empty',
                              onPressed: () => setState(() =>
                                  _autoHideDownloads = !_autoHideDownloads),
                            ),
                          ],
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
                if (downloadsVisible) ...[
                  const VerticalDivider(width: 1),
                  const Expanded(child: DownloadsView()),
                ],
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
