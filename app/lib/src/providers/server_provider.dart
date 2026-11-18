// Riverpod providers for the Landir host server lifecycle.

import 'dart:io';
import 'dart:math';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

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
  final int? port;
  final String? url;
  final String? token;
  final bool insecure;
  final String? error;
  final String? hotspotSsid;

  const ServerState({
    this.running = false,
    this.port,
    this.url,
    this.token,
    this.insecure = false,
    this.error,
    this.hotspotSsid,
  });

  ServerState copyWith({
    bool? running,
    int? port,
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
        port: 8000,
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
      final pagePath = token != null ? '/$token/' : '/';
      final url = 'http://${addr.address}:$port$pagePath';

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
    state = const ServerState();
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
    state = ServerState(insecure: !state.insecure);
  }

  String _generateToken() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-';
    final rng = Random.secure();
    return String.fromCharCodes(Iterable.generate(
        22, (_) => chars.codeUnitAt(rng.nextInt(chars.length))));
  }
}
