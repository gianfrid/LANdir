// Landir app entry point. Adaptive layout: side-by-side Host/Client on
// wide (desktop) windows, bottom-nav tabs on narrow (phone) screens.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

class _AdaptiveHome extends StatefulWidget {
  const _AdaptiveHome();

  @override
  State<_AdaptiveHome> createState() => _AdaptiveHomeState();
}

class _AdaptiveHomeState extends State<_AdaptiveHome> {
  int _tab = 0;

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
