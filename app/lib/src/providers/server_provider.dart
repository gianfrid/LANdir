// Riverpod providers for the LANdir host server lifecycle.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/crypto.dart';
import '../core/file_sink.dart';
import '../core/server.dart';
import '../network_info.dart';
import '../platform/documents_sink.dart';
import '../platform/folder_picker.dart';
import '../platform/hotspot.dart';
import '../platform/media_store_sink.dart';

part 'server_provider.g.dart';

/// Immutable state of the host server.
class ServerState {
  static const _unsetError = Object();
  static const _unsetWarning = Object();

  final bool running;
  final int? port; // bound port while running
  final int requestedPort; // port for the next start; 0 = pick a free one
  final String? url;
  final String? token;

  /// Whether encryption mode is on for the next start (design 001): the
  /// QR/URL carries the host key (`#k=`) and only the sealed endpoints
  /// answer; off means a keyless, plaintext host like the CLI servers.
  /// Default on: encryption is the reason the app host exists.
  final bool encrypted;
  final bool insecure;
  final String? error;

  /// Non-fatal condition the user must know about (transient like
  /// [error]: reset unless explicitly passed).
  final String? warning;
  final String? hotspotSsid;

  /// Where received files are saved (desktop only). Null means the
  /// default location (the Documents directory).
  final String? saveDir;

  const ServerState({
    this.running = false,
    this.port,
    this.requestedPort = 8000,
    this.url,
    this.token,
    this.encrypted = true,
    this.insecure = false,
    this.error,
    this.warning,
    this.hotspotSsid,
    this.saveDir,
  });

  ServerState copyWith({
    bool? running,
    int? port,
    int? requestedPort,
    String? url,
    String? token,
    bool? encrypted,
    bool? insecure,
    // Null clears the error, so a sentinel marks "argument not given".
    Object? error = _unsetError,
    // Same sentinel convention as error.
    Object? warning = _unsetWarning,
    String? hotspotSsid,
    String? saveDir,
  }) =>
      ServerState(
        running: running ?? this.running,
        port: port ?? this.port,
        requestedPort: requestedPort ?? this.requestedPort,
        url: url ?? this.url,
        token: token ?? this.token,
        encrypted: encrypted ?? this.encrypted,
        insecure: insecure ?? this.insecure,
        error: identical(error, _unsetError)
            ? this.error
            : error as String?,
        warning: identical(warning, _unsetWarning)
            ? this.warning
            : warning as String?,
        hotspotSsid: hotspotSsid ?? this.hotspotSsid,
        saveDir: saveDir ?? this.saveDir,
      );
}

/// Whether the user can choose the Save directory. Android writes through
/// MediaStore (fixed), and iOS must keep the app Documents directory so
/// received files appear in the Files app — only desktop has a choice.
bool get canChooseSaveDir => !Platform.isAndroid && !Platform.isIOS;

const String _saveDirPrefsKey = 'save_dir';

/// Picks the FileSink for the current platform.
@riverpod
Future<FileSink> fileSink(Ref ref) async {
  if (Platform.isAndroid) return MediaStoreFileSink();
  // Desktop: honor the user's chosen Save directory if one is persisted;
  // iOS keeps the app Documents directory (Files-app visibility).
  if (canChooseSaveDir) {
    final prefs = await SharedPreferences.getInstance();
    final custom = prefs.getString(_saveDirPrefsKey);
    if (custom != null && custom.isNotEmpty) {
      return DocumentsFileSink.withRootDir(custom);
    }
  }
  return DocumentsFileSink.create();
}

/// The URL clients are told to open (GLOSSARY: Advertised URL): always
/// built from the bound port, so an occupied requested port that fell
/// back is advertised correctly.
@visibleForTesting
String advertisedUrl(String address, int port, String? token) =>
    'http://$address:$port${token != null ? '/$token/' : '/'}';

/// The running LANdirServer instance (kept alive while running).
@riverpod
class ServerController extends _$ServerController {
  LANdirServer? _server;

  @override
  ServerState build() => const ServerState();

  Future<void> start() async {
    if (state.running) return;
    state = state.copyWith(error: null, warning: null);
    try {
      final sink = await ref.read(fileSinkProvider.future);
      // The server core needs a real, app-writable directory for safeName's
      // realpath/containment and collision checks. Actual file bytes go
      // through the FileSink (MediaStore on Android, Documents on iOS).
      final appDir = await getApplicationSupportDirectory();
      final uploadDir = '${appDir.path}/uploads';
      Directory(uploadDir).createSync(recursive: true);

      // Disentangled access controls (ADR 0003): an encrypted host uses
      // fixed root paths with the host key as the ONLY gate — no token is
      // generated, so the Secret URL mode choice is inert while the mode
      // is on. A keyless host keeps the CLI hosts' contract, where the
      // token is the capability.
      final token =
          (state.encrypted || state.insecure) ? null : _generateToken();
      final config = ServerConfig(
        port: state.requestedPort,
        uploadDir: uploadDir,
        insecure: token == null,
        secretToken: token,
        encrypted: state.encrypted,
      );
      // Host key (design 001, M1): generated once and persisted in the
      // app-support directory — never under uploads/. Only loaded in
      // encryption mode: there it is the ONLY way in (plaintext endpoints
      // answer 404); with the mode off the host is keyless, like the CLI
      // servers, and the key is never shown.
      final hostKey = state.encrypted
          ? await HostKeyStore(appDir.path).loadOrCreate()
          : null;
      _server = LANdirServer(config, sink, hostKey: hostKey);
      await _server!.start();
      final port = _server!.boundPort;

      // Try LocalOnlyHotspot on Android for a predictable gateway IP
      String? hotspotSsid;
      final hotspot = await requestLocalOnlyHotspot();
      if (hotspot != null) {
        hotspotSsid = hotspot.ssid;
      }

      final addr = await findBestAddress();
      final url = state.encrypted
          ? (advertisedUrlWithKey(addr.address, port, null, hostKey!.publicKey) ??
              advertisedUrl(addr.address, port, null))
          : advertisedUrl(addr.address, port, token);
      // In encryption mode the key is the only gate: if it does not fit the
      // QR, no client can pair at all (everything else answers 404).
      final warning = state.encrypted && !url.contains('#k=')
          ? 'The address is too long for the QR code, so the host key could '
              'not be included. App clients will NOT be able to connect — '
              'use a shorter address or turn Encryption off.'
          : null;

      state = state.copyWith(
        running: true,
        port: port,
        url: url,
        token: token,
        hotspotSsid: hotspotSsid,
        warning: warning,
      );

      if (Platform.isAndroid) {
        await _startForegroundService(port);
      }
    } catch (e) {
      state = state.copyWith(running: false, error: e.toString());
    }
  }

  /// Write files picked on this device straight into the running host's
  /// sink (host-view "Add files"), bypassing HTTP but using the same
  /// sanitization and collision handling as a remote upload — so a local
  /// add lands in the same place (MediaStore Downloads on Android) with
  /// the same naming rules. Fails as a batch-level no-op while stopped.
  Future<LocalFilesResult> addLocalFiles(List<PlatformFile> files) async {
    final server = _server;
    if (!state.running || server == null) {
      return const LocalFilesResult(0, ['server is not running']);
    }
    final local = <LocalFile>[];
    final failures = <String>[];
    for (final f in files) {
      try {
        // xFile works for SAF content:// picks too, where path may be null.
        local.add(LocalFile(f.name, await f.xFile.readAsBytes()));
      } catch (e) {
        failures.add('${f.name}: $e');
      }
    }
    final result =
        await saveLocalFiles(server.sink, server.config.uploadDir, local);
    return LocalFilesResult(result.ok, [...failures, ...result.failures]);
  }

  /// Pick a whole folder on this device and write every file in it into
  /// the running host's sink, preserving the folder structure
  /// ("sub/photo.jpg"). Same guard and sanitization as [addLocalFiles].
  Future<LocalFilesResult> addLocalFolder(Uri treeUri) async {
    final server = _server;
    if (!state.running || server == null) {
      return const LocalFilesResult(0, ['server is not running']);
    }
    final failures = <String>[];
    final List<LocalPathFile> files;
    try {
      final entries = await listFolderTree(treeUri);
      final list = <LocalPathFile>[];
      for (final e in entries) {
        try {
          list.add(LocalPathFile(
              e.relativePath, await readTreeFile(treeUri, e.relativePath)));
        } catch (err) {
          failures.add('${e.relativePath}: $err');
        }
      }
      files = list;
    } catch (e) {
      return LocalFilesResult(0, ['folder unreadable: $e']);
    }
    final result =
        await saveLocalPaths(server.sink, server.config.uploadDir, files);
    return LocalFilesResult(result.ok, [...failures, ...result.failures]);
  }

  Future<void> stop() async {
    await _server?.stop();
    _server = null;
    if (Platform.isAndroid) {
      await FlutterForegroundTask.stopService();
    }
    // Keep the user's port, encryption, and Save directory choices (and
    // the error) out of the reset: they are preferences, not runtime state.
    state = ServerState(
      requestedPort: state.requestedPort,
      encrypted: state.encrypted,
      saveDir: state.saveDir,
    );
  }

  Future<void> _startForegroundService(int port) async {
    await FlutterForegroundTask.startService(
      notificationTitle: 'LANdir is serving',
      notificationText: 'Port $port — tap to open',
      callback: _foregroundCallback,
    );
  }

  @pragma('vm:entry-point')
  static void _foregroundCallback() {
    // The server itself runs in the main isolate; this callback just keeps
    // the Android foreground service alive while the server is up.
    FlutterForegroundTask.updateService(
      notificationTitle: 'LANdir is serving',
      notificationText: 'Receiving files on the local network',
    );
  }

  void toggleInsecure() {
    if (state.running) return; // only changeable while stopped
    state = state.copyWith(insecure: !state.insecure);
  }

  static const _requestedPortPrefsKey = 'requested_port';
  static const _encryptedPrefsKey = 'encrypted';

  /// Toggle encryption mode (only changeable while stopped; persists
  /// across app restarts like the port and Save directory choices): on =
  /// QR carries the host key and only sealed clients get in; off = a
  /// keyless, plaintext host that browsers and CLI peers can use.
  void toggleEncrypted() {
    if (state.running) return;
    state = state.copyWith(encrypted: !state.encrypted);
    unawaited(_saveEncrypted(state.encrypted));
  }

  Future<void> _saveEncrypted(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_encryptedPrefsKey, value);
  }

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

  /// Select the directory received files are saved into (desktop only).
  /// Null clears the choice and returns to the default Documents
  /// directory. Only changeable while stopped; persists across app
  /// restarts like the port.
  void setSaveDir(String? dir) {
    if (state.running) return;
    final normalized = (dir == null || dir.isEmpty) ? null : dir;
    // A fresh ServerState rather than copyWith: null means "argument not
    // given" there, but here it clears the choice.
    state = ServerState(
      requestedPort: state.requestedPort,
      encrypted: state.encrypted,
      insecure: state.insecure,
      saveDir: normalized,
    );
    unawaited(_saveSaveDir(normalized));
  }

  Future<void> _saveSaveDir(String? dir) async {
    final prefs = await SharedPreferences.getInstance();
    if (dir == null) {
      await prefs.remove(_saveDirPrefsKey);
    } else {
      await prefs.setString(_saveDirPrefsKey, dir);
    }
  }

  /// Restores the persisted choices if the app starts fresh (the host
  /// view calls this once on creation, mirroring the client view).
  Future<void> loadPersistedSettings() async {
    if (state.running) return;
    final prefs = await SharedPreferences.getInstance();
    final savedPort = prefs.getInt(_requestedPortPrefsKey);
    if (savedPort != null && ServerConfig.isValidPort(savedPort)) {
      state = state.copyWith(requestedPort: savedPort);
    }
    final savedDir = prefs.getString(_saveDirPrefsKey);
    if (savedDir != null && savedDir.isNotEmpty) {
      state = state.copyWith(saveDir: savedDir);
    }
    final savedEncrypted = prefs.getBool(_encryptedPrefsKey);
    if (savedEncrypted != null) {
      state = state.copyWith(encrypted: savedEncrypted);
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
