// Riverpod providers for the client role (M3): server registry, file
// browsing, upload, download.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/client.dart';
import '../core/security.dart';
import '../core/share.dart';

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

  /// Base URL of a server that answered 404 and was removed from the
  /// registry. Set once so the UI can tell the user; cleared by
  /// [ClientController.acknowledgeRemovedServer].
  final String? removedServerUrl;

  /// A server whose URL points outside the LAN (public IP or DNS name).
  /// Held here until the user confirms adding it; null otherwise.
  final SavedServer? pendingNonLanServer;

  /// Items received through the platform share sheet while no server was
  /// selected. Uploaded (and the list cleared) as soon as one is.
  final List<IncomingShare> pendingShares;

  const ClientState({
    this.servers = const [],
    this.current,
    this.currentPath = '',
    this.files = const [],
    this.loading = false,
    this.error,
    this.statusMessage,
    this.removedServerUrl,
    this.pendingNonLanServer,
    this.pendingShares = const [],
  });

  /// Null conventions differ by field, matching how each is used:
  /// - `error`, `statusMessage`, `removedServerUrl` are transient messages:
  ///   they are always reset unless a non-null value is passed.
  /// - `current` cannot be reset by passing null (that means "keep"), so
  ///   [clearCurrent] exists; callers clearing `current` reset
  ///   `currentPath`/`files` explicitly.
  ClientState copyWith({
    List<SavedServer>? servers,
    SavedServer? current,
    bool clearCurrent = false,
    String? currentPath,
    List<RemoteFile>? files,
    bool? loading,
    String? error,
    String? statusMessage,
    String? removedServerUrl,
    SavedServer? pendingNonLanServer,
    bool clearPendingNonLanServer = false,
    List<IncomingShare>? pendingShares,
  }) =>
      ClientState(
        servers: servers ?? this.servers,
        current: clearCurrent ? null : (current ?? this.current),
        currentPath: currentPath ?? this.currentPath,
        files: files ?? this.files,
        loading: loading ?? this.loading,
        error: error,
        statusMessage: statusMessage,
        removedServerUrl: removedServerUrl,
        pendingNonLanServer:
            clearPendingNonLanServer ? null : (pendingNonLanServer ?? this.pendingNonLanServer),
        pendingShares: pendingShares ?? this.pendingShares,
      );
}

/// True when the file browser should leave its route: the server it was
/// browsing was deselected (deleted manually, or dropped after a 404).
///
/// Keyed on the `current` transition rather than the one-shot
/// [ClientState.removedServerUrl] flag, so it cannot be affected by the
/// order in which listeners are notified (the client view acknowledges the
/// flag, which clears it).
bool shouldLeaveBrowser(ClientState? prev, ClientState next) {
  return prev?.current != null && next.current == null;
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
  ///
  /// URLs pointing outside the LAN (public IP or DNS name) are not added
  /// directly: they land in [ClientState.pendingNonLanServer] and the UI
  /// must confirm them via [confirmPendingNonLanServer]. Landir is
  /// LAN-only; a public address usually means a mistyped or malicious QR.
  void addServer(String rawUrl) {
    var url = rawUrl.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    if (!url.endsWith('/')) url += '/';
    final name = Uri.parse(url).host;
    final server = SavedServer(name: name, baseUrl: url);
    if (!isLanHost(name)) {
      state = state.copyWith(pendingNonLanServer: server);
      return;
    }
    _add(server);
  }

  /// Add the pending non-LAN server after the user confirmed the warning.
  void confirmPendingNonLanServer() {
    final server = state.pendingNonLanServer;
    if (server == null) return;
    _add(server);
  }

  /// Discard the pending non-LAN server (user declined).
  void cancelPendingNonLanServer() {
    state = state.copyWith(clearPendingNonLanServer: true);
  }

  void _add(SavedServer server) {
    final servers = [
      ...state.servers.where((s) => s.baseUrl != server.baseUrl),
      server
    ];
    state = state.copyWith(
      servers: servers,
      error: null,
      clearPendingNonLanServer: true,
    );
    _persistServers(servers);
  }

  void removeServer(String baseUrl) {
    _dropServer(baseUrl);
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
    } on ServerGoneException {
      _forgetServer(server);
      return;
    } catch (e) {
      state = state.copyWith(
          loading: false, error: 'Cannot reach server: $e');
      return;
    }
    // Shares that arrived while no server was selected: flush them now.
    final pending = state.pendingShares;
    if (pending.isNotEmpty) {
      state = state.copyWith(pendingShares: const []);
      await _uploadShares(pending);
    }
  }

  /// Handle shares arriving via the platform share sheet. Uploads
  /// immediately when a server is selected; otherwise holds them until the
  /// user picks one (see [selectServer]).
  Future<void> receiveShares(List<IncomingShare> shares) async {
    if (shares.isEmpty) return;
    if (state.current == null) {
      state = state.copyWith(
        pendingShares: [...state.pendingShares, ...shares],
        statusMessage:
            'Select a server to upload ${shares.length} shared item(s)',
      );
      return;
    }
    await _uploadShares(shares);
  }

  /// Upload a batch of shares to the current server, one by one. Per-file
  /// errors are counted, not fatal: one unreadable share must not block the
  /// rest of the batch.
  Future<void> _uploadShares(List<IncomingShare> shares) async {
    var ok = 0;
    for (final share in shares) {
      try {
        final Uint8List bytes;
        if (share.isText) {
          bytes = Uint8List.fromList(utf8.encode(share.text!));
        } else {
          bytes = await File(share.filePath!).readAsBytes();
        }
        if (await uploadFile(share.filename, bytes)) ok++;
      } catch (_) {
        state = state.copyWith(loading: false);
      }
    }
    if (ok < shares.length) {
      state = state.copyWith(
          error: 'Uploaded $ok of ${shares.length} shared item(s)');
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
    } on ServerGoneException {
      _forgetServer(current);
    } catch (e) {
      state = state.copyWith(loading: false, error: 'Refresh failed: $e');
    }
  }

  /// The server answered 404: it no longer exists (stopped, restarted with a
  /// new token, or moved). Drop it from the registry and deselect it.
  void _forgetServer(SavedServer server) {
    _client?.close();
    _client = null;
    _dropServer(
      server.baseUrl,
      error: 'Server ${server.name} no longer exists (404) — removed from '
          'your server list.',
      removedUrl: server.baseUrl,
    );
  }

  /// Remove [baseUrl] from the registry, deselect it if it is current, and
  /// persist. [error]/[removedUrl] are set only when the server was dropped
  /// because it answered 404 (see [_forgetServer]).
  void _dropServer(String baseUrl, {String? error, String? removedUrl}) {
    final servers = state.servers.where((s) => s.baseUrl != baseUrl).toList();
    final wasCurrent = state.current?.baseUrl == baseUrl;
    state = state.copyWith(
      servers: servers,
      clearCurrent: wasCurrent,
      currentPath: wasCurrent ? '' : state.currentPath,
      files: wasCurrent ? const [] : state.files,
      loading: false,
      error: error,
      removedServerUrl: removedUrl,
    );
    _persistServers(servers);
  }

  /// Clear the "server removed" flag once the UI has shown it.
  void acknowledgeRemovedServer() {
    state = state.copyWith(removedServerUrl: null);
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
