// Riverpod providers for the client role (M3): server registry, file
// browsing, upload, download.

import 'dart:convert';
import 'dart:typed_data';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/client.dart';

part 'client_provider.g.dart';

const String _serversPrefsKey = 'landir_saved_servers';

/// A saved Landir server entry.
class SavedServer {
  final String name;
  final String baseUrl;

  const SavedServer({required this.name, required this.baseUrl});

  SavedServer copyWith({String? name, String? baseUrl}) => SavedServer(
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
      );
}

/// Client state: saved servers, the currently selected server, and its
/// file listing.
class ClientState {
  final List<SavedServer> servers;
  final SavedServer? current;
  final String currentPath; // '' = root, 'a/b' = nested
  final List<RemoteFile> files;
  final bool loading;
  final String? error;
  final String? statusMessage;

  const ClientState({
    this.servers = const [],
    this.current,
    this.currentPath = '',
    this.files = const [],
    this.loading = false,
    this.error,
    this.statusMessage,
  });

  ClientState copyWith({
    List<SavedServer>? servers,
    SavedServer? current,
    String? currentPath,
    List<RemoteFile>? files,
    bool? loading,
    String? error,
    String? statusMessage,
  }) =>
      ClientState(
        servers: servers ?? this.servers,
        current: current ?? this.current,
        currentPath: currentPath ?? this.currentPath,
        files: files ?? this.files,
        loading: loading ?? this.loading,
        error: error,
        statusMessage: statusMessage,
      );
}

@riverpod
class ClientController extends _$ClientController {
  LandirClient? _client;

  @override
  ClientState build() => const ClientState();

  /// Load persisted servers from shared_preferences. Call once on app start.
  Future<void> loadPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_serversPrefsKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List<dynamic>)
          .map((e) => SavedServer(
                name: e['name'] as String,
                baseUrl: e['baseUrl'] as String,
              ))
          .toList();
      state = state.copyWith(servers: list);
    } catch (_) {}
  }

  Future<void> _persistServers(List<SavedServer> servers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _serversPrefsKey,
      jsonEncode(servers
          .map((s) => {'name': s.name, 'baseUrl': s.baseUrl}).toList()),
    );
  }

  /// Add a server from a URL (typically scanned from a QR code or typed).
  /// Normalizes the URL to end with '/'.
  void addServer(String rawUrl) {
    var url = rawUrl.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    if (!url.endsWith('/')) url += '/';
    final name = Uri.parse(url).host;
    final server = SavedServer(name: name, baseUrl: url);
    final servers = [...state.servers.where((s) => s.baseUrl != url), server];
    state = state.copyWith(servers: servers, error: null);
    _persistServers(servers);
  }

  void removeServer(String baseUrl) {
    final servers = state.servers.where((s) => s.baseUrl != baseUrl).toList();
    final current = state.current?.baseUrl == baseUrl ? null : state.current;
    state = state.copyWith(servers: servers, current: current);
    _persistServers(servers);
  }

  /// Select a server and fetch its root listing.
  Future<void> selectServer(SavedServer server) async {
    state = state.copyWith(
        current: server, currentPath: '', loading: true, error: null, files: []);
    _client?.close();
    _client = LandirClient(server.baseUrl);
    try {
      final files = await _client!.listDir('');
      state = state.copyWith(files: files, loading: false);
    } catch (e) {
      state = state.copyWith(
          loading: false, error: 'Cannot reach server: $e');
    }
  }

  /// Refresh the current directory listing.
  Future<void> refresh() async {
    final client = _client;
    final current = state.current;
    if (client == null || current == null) return;
    state = state.copyWith(loading: true, error: null);
    try {
      final files = await client.listDir(state.currentPath);
      state = state.copyWith(files: files, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: 'Refresh failed: $e');
    }
  }

  /// Navigate into a subdirectory.
  Future<void> navigateInto(String dirName) async {
    final base = state.currentPath;
    final path = base.isEmpty ? dirName : '$base/$dirName';
    state = state.copyWith(currentPath: path);
    await refresh();
  }

  /// Navigate up one level.
  Future<void> navigateUp() async {
    final parts = state.currentPath.split('/');
    if (parts.length <= 1) {
      state = state.copyWith(currentPath: '');
    } else {
      parts.removeLast();
      state = state.copyWith(currentPath: parts.join('/'));
    }
    await refresh();
  }

  /// Upload a file to the current server. Returns true on success.
  Future<bool> uploadFile(String filename, Uint8List content) async {
    final client = _client;
    final current = state.current;
    if (client == null || current == null) return false;
    state = state.copyWith(
        loading: true, error: null, statusMessage: 'Uploading $filename...');
    try {
      final ok = await client.uploadFile(filename, content);
      if (ok) {
        state = state.copyWith(
            loading: false, statusMessage: 'Uploaded $filename');
        await refresh();
      } else {
        state = state.copyWith(
            loading: false, error: 'Upload failed (server returned error)');
      }
      return ok;
    } catch (e) {
      state = state.copyWith(loading: false, error: 'Upload error: $e');
      return false;
    }
  }

  /// Download a file from the current server by its path relative to the
  /// server root (e.g. 'flutter-apk/app.apk' when inside a folder).
  /// Returns the bytes.
  Future<Uint8List?> downloadFile(String relPath) async {
    final client = _client;
    if (client == null) return null;
    final name = relPath.split('/').last;
    state = state.copyWith(
        loading: true, error: null, statusMessage: 'Downloading $name...');
    try {
      final bytes = await client.downloadFile(relPath);
      state = state.copyWith(
          loading: false, statusMessage: 'Downloaded $name');
      return bytes;
    } catch (e) {
      state = state.copyWith(loading: false, error: 'Download error: $e');
      return null;
    }
  }
}
