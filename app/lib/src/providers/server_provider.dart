// Riverpod providers for the Landir host server lifecycle.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/file_sink.dart';
import '../core/server.dart';
import '../network_info.dart';
import '../platform/documents_sink.dart';
import '../platform/hotspot.dart';
import '../platform/media_store_sink.dart';

part 'server_provider.g.dart';

/// Immutable state of the host server.
class ServerState {
  static const _unsetError = Object();

  final bool running;
  final int? port; // bound port while running
  final int requestedPort; // port for the next start; 0 = pick a free one
  final String? url;
  final String? token;
  final bool insecure;
  final String? error;
  final String? hotspotSsid;

  const ServerState({
    this.running = false,
    this.port,
    this.requestedPort = 8000,
    this.url,
    this.token,
    this.insecure = false,
    this.error,
    this.hotspotSsid,
  });

  ServerState copyWith({
    bool? running,
    int? port,
    int? requestedPort,
    String? url,
    String? token,
    bool? insecure,
    // Null clears the error, so a sentinel marks "argument not given".
    Object? error = _unsetError,
    String? hotspotSsid,
  }) =>
      ServerState(
        running: running ?? this.running,
        port: port ?? this.port,
        requestedPort: requestedPort ?? this.requestedPort,
        url: url ?? this.url,
        token: token ?? this.token,
        insecure: insecure ?? this.insecure,
        error: identical(error, _unsetError)
            ? this.error
            : error as String?,
        hotspotSsid: hotspotSsid ?? this.hotspotSsid,
      );
}

/// Picks the FileSink for the current platform.
@riverpod
Future<FileSink> fileSink(Ref ref) async {
  if (Platform.isAndroid) return MediaStoreFileSink();
  return DocumentsFileSink.create();
}

/// The URL clients are told to open (GLOSSARY: Advertised URL): always
/// built from the bound port, so an occupied requested port that fell
/// back is advertised correctly.
@visibleForTesting
String advertisedUrl(String address, int port, String? token) =>
    'http://$address:$port${token != null ? '/$token/' : '/'}';

/// The running LandirServer instance (kept alive while running).
@riverpod
class ServerController extends _$ServerController {
  LandirServer? _server;

  @override
  ServerState build() => const ServerState();

  Future<void> start() async {
    if (state.running) return;
    state = state.copyWith(error: null);
    try {
      final sink = await ref.read(fileSinkProvider.future);
      // The server core needs a real, app-writable directory for safeName's
      // realpath/containment and collision checks. Actual file bytes go
      // through the FileSink (MediaStore on Android, Documents on iOS).
      final appDir = await getApplicationSupportDirectory();
      final uploadDir = '${appDir.path}/uploads';
      Directory(uploadDir).createSync(recursive: true);

      final token = state.insecure ? null : _generateToken();
      final config = ServerConfig(
        port: state.requestedPort,
        uploadDir: uploadDir,
        insecure: state.insecure,
        secretToken: token,
      );
      _server = LandirServer(config, sink);
      await _server!.start();
      final port = _server!.boundPort;

      // Try LocalOnlyHotspot on Android for a predictable gateway IP
      String? hotspotSsid;
      final hotspot = await requestLocalOnlyHotspot();
      if (hotspot != null) {
        hotspotSsid = hotspot.ssid;
      }

      final addr = await findBestAddress();
      final url = advertisedUrl(addr.address, port, token);

      state = state.copyWith(
        running: true,
        port: port,
        url: url,
        token: token,
        hotspotSsid: hotspotSsid,
      );

      if (Platform.isAndroid) {
        await _startForegroundService(port);
      }
    } catch (e) {
      state = state.copyWith(running: false, error: e.toString());
    }
  }

  Future<void> stop() async {
    await _server?.stop();
    _server = null;
    if (Platform.isAndroid) {
      await FlutterForegroundTask.stopService();
    }
    // Keep the user's port choice (and the error) out of the reset: the
    // port is a preference, not runtime state.
    state = ServerState(requestedPort: state.requestedPort);
  }

  Future<void> _startForegroundService(int port) async {
    await FlutterForegroundTask.startService(
      notificationTitle: 'Landir is serving',
      notificationText: 'Port $port — tap to open',
      callback: _foregroundCallback,
    );
  }

  @pragma('vm:entry-point')
  static void _foregroundCallback() {
    // The server itself runs in the main isolate; this callback just keeps
    // the Android foreground service alive while the server is up.
    FlutterForegroundTask.updateService(
      notificationTitle: 'Landir is serving',
      notificationText: 'Receiving files on the local network',
    );
  }

  void toggleInsecure() {
    if (state.running) return; // only changeable while stopped
    state = state.copyWith(insecure: !state.insecure);
  }

  static const _requestedPortPrefsKey = 'requested_port';

  /// Select the port for the next start. 0 means the server picks a free
  /// dynamic-range port itself. Only changeable while stopped; persists
  /// across app restarts (same store as the client registry).
  void setPort(int port) {
    if (state.running) return;
    if (!ServerConfig.isValidPort(port)) return;
    state = state.copyWith(requestedPort: port);
    unawaited(_saveRequestedPort(port));
  }

  Future<void> _saveRequestedPort(int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_requestedPortPrefsKey, port);
  }

  /// Restores the persisted port choice if the app starts fresh (the
  /// host view calls this once on creation, mirroring the client view).
  Future<void> loadPersistedPort() async {
    if (state.running) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_requestedPortPrefsKey);
    if (saved != null && ServerConfig.isValidPort(saved)) {
      state = state.copyWith(requestedPort: saved);
    }
  }

  String _generateToken() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-';
    final rng = Random.secure();
    return String.fromCharCodes(Iterable.generate(
        22, (_) => chars.codeUnitAt(rng.nextInt(chars.length))));
  }
}
