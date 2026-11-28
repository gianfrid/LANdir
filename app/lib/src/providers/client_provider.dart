// Riverpod providers for the client role (M3): server registry, file
// browsing, upload, download.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/client.dart';
import '../core/crypto.dart';
import '../core/security.dart';
import '../core/share.dart';

part 'client_provider.g.dart';

const String _serversPrefsKey = 'landir_saved_servers';
const String _lastServerPrefsKey = 'landir_last_server';

/// A saved LANdir server entry.
class SavedServer {
  final String name;
  final String baseUrl;

  /// Pinned host key as base64url (no padding), or null for a keyless host
  /// (a landir.py / Rust host whose QR carries no #k=). Pinned to
  /// (host, port), never to the per-run token — see [hostPortKey].
  final String? hostKey;

  const SavedServer({required this.name, required this.baseUrl, this.hostKey});

  /// Identity the pin is bound to: scheme + host + port, token excluded.
  String get hostPortKey {
    final uri = Uri.parse(baseUrl);
    return '${uri.scheme}://${uri.host}:${uri.port}';
  }

  Uint8List? get hostKeyBytes => hostKey == null
      ? null
      : Uint8List.fromList(base64Url.decode(padBase64Url(hostKey!)));

  SavedServer copyWith({String? name, String? baseUrl, String? hostKey}) =>
      SavedServer(
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        hostKey: hostKey ?? this.hostKey,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'baseUrl': baseUrl,
        if (hostKey != null) 'hostKey': hostKey,
      };

  factory SavedServer.fromJson(Map<String, dynamic> json) => SavedServer(
        name: json['name'] as String,
        baseUrl: json['baseUrl'] as String,
        hostKey: json['hostKey'] as String?,
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

  /// Base URL of a server that was dropped from the registry because it can
  /// never work again (404, or a sealed listing that no longer authenticates
  /// under the pinned key). Set once so the UI can tell the user why;
  /// [ClientState.removedServerReason] carries the human-readable sentence;
  /// both are cleared by [ClientController.acknowledgeRemovedServer].
  final String? removedServerUrl;

  /// Why the server at [ClientState.removedServerUrl] was dropped, shown to
  /// the user by the client view (the URL alone is not enough to tell a 404
  /// apart from a stale pin).
  final String? removedServerReason;

  /// A server whose URL points outside the LAN (public IP or DNS name).
  /// Held here until the user confirms adding it; null otherwise.
  final SavedServer? pendingNonLanServer;

  /// A rescan presented a different host key for an already-pinned
  /// (host, port). The add is blocked until the user explicitly re-pairs via
  /// [ClientController.confirmRekey] (Signal safety-number pattern).
  final ({SavedServer existing, SavedServer scanned})? pendingKeyConflict;

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
    this.removedServerReason,
    this.pendingNonLanServer,
    this.pendingKeyConflict,
    this.pendingShares = const [],
  });

  /// Null conventions differ by field, matching how each is used:
  /// - `error`, `statusMessage`, `removedServerUrl`, `removedServerReason`
  ///   are transient messages: they are always reset unless a non-null value
  ///   is passed.
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
    String? removedServerReason,
    SavedServer? pendingNonLanServer,
    bool clearPendingNonLanServer = false,
    ({SavedServer existing, SavedServer scanned})? pendingKeyConflict,
    bool clearPendingKeyConflict = false,
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
        removedServerReason: removedServerReason,
        pendingNonLanServer:
            clearPendingNonLanServer ? null : (pendingNonLanServer ?? this.pendingNonLanServer),
        pendingKeyConflict: clearPendingKeyConflict
            ? null
            : (pendingKeyConflict ?? this.pendingKeyConflict),
        pendingShares: pendingShares ?? this.pendingShares,
      );
}

/// True when the file browser should leave its route: the server it was
/// browsing was deselected (deleted manually, or dropped as unusable after a
/// 404 or a failed sealed listing).
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
  LANdirClient? _client;

  @override
  ClientState build() => const ClientState();

  /// Load persisted servers from shared_preferences. Call once on app start.
  /// If a server was selected the last time the app ran, reconnect to it.
  ///
  /// Registry format is versioned: v1 is `{'v': 1, 'servers': [...]}` with an
  /// optional `hostKey` per entry; the legacy bare-list format (pre-pinning)
  /// migrates with hostKey = null.
  Future<void> loadPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_serversPrefsKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        final List<dynamic> list;
        if (decoded is Map<String, dynamic>) {
          list = (decoded['servers'] as List<dynamic>? ?? const []);
        } else {
          list = decoded as List<dynamic>;
        }
        final servers =
            list.map((e) => SavedServer.fromJson(e as Map<String, dynamic>)).toList();
        state = state.copyWith(servers: servers);
      } catch (_) {}
    }
    final lastUrl = prefs.getString(_lastServerPrefsKey);
    if (lastUrl == null) return;
    final match = state.servers.where((s) => s.baseUrl == lastUrl).toList();
    if (match.isNotEmpty) {
      await selectServer(match.first);
    } else {
      // The saved server was removed while the app was closed.
      await prefs.remove(_lastServerPrefsKey);
    }
  }

  Future<void> _persistServers(List<SavedServer> servers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _serversPrefsKey,
      jsonEncode({
        'v': 1,
        'servers': servers.map((s) => s.toJson()).toList(),
      }),
    );
  }

  /// Add a server from a URL (typically scanned from a QR code or typed).
  /// Normalizes the URL to end with '/' and extracts the pinned host key
  /// from the `#k=` fragment when present (design 001, M3).
  ///
  /// URLs pointing outside the LAN (public IP or DNS name) are not added
  /// directly: they land in [ClientState.pendingNonLanServer] and the UI
  /// must confirm them via [confirmPendingNonLanServer]. LANdir is
  /// LAN-only; a public address usually means a mistyped or malicious QR.
  ///
  /// A scan presenting a different host key for an already-pinned
  /// (host, port) is blocked into [ClientState.pendingKeyConflict] — the
  /// user must explicitly re-pair via [confirmRekey].
  void addServer(String rawUrl) {
    var url = rawUrl.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    final parsed = parsePairedUrl(url);
    final url2 = parsed.baseUrl;
    final name = Uri.parse(url2).host;
    final server = SavedServer(
      name: name,
      baseUrl: url2,
      hostKey: parsed.hostKey == null
          ? null
          : base64Url.encode(parsed.hostKey!).replaceAll('=', ''),
    );
    if (!isLanHost(name)) {
      state = state.copyWith(pendingNonLanServer: server);
      return;
    }
    _add(server);
  }

  /// Adopt the rescanned key after a [pendingKeyConflict]: updates the pin
  /// for that (host, port) and adds/refreshes the server entry.
  void confirmRekey() {
    final conflict = state.pendingKeyConflict;
    if (conflict == null) return;
    state = state.copyWith(clearPendingKeyConflict: true);
    _add(conflict.scanned, force: true);
  }

  /// Discard a [pendingKeyConflict] (user declined to re-pair).
  void cancelRekey() {
    state = state.copyWith(clearPendingKeyConflict: true);
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

  void _add(SavedServer server, {bool force = false}) {
    // Pin conflict check: same (host, port) with a change to the pin state.
    // Keyless -> keyed is allowed (host upgraded). Keyed -> anything else —
    // a different key OR NO key at all (QR without #k=, typed URL) — blocks
    // for explicit re-pair (Noise §14 rollback discipline: a pinned server
    // is always sealed, never silently downgraded to plaintext) unless
    // [force] (the user just confirmed the re-pair explicitly).
    if (!force) {
      final sameHostPort = state.servers
          .where((s) => s.hostPortKey == server.hostPortKey)
          .toList();
      for (final existing in sameHostPort) {
        if (existing.hostKey != null && existing.hostKey != server.hostKey) {
          state = state.copyWith(
            pendingKeyConflict: (existing: existing, scanned: server),
            error: null,
          );
          return;
        }
      }
    }
    final servers = [
      ...state.servers.where((s) =>
          s.baseUrl != server.baseUrl && s.hostPortKey != server.hostPortKey),
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

  /// Select a server and fetch its root listing. The selection is persisted
  /// so the app reconnects to it on next start (see [loadPersisted]).
  Future<void> selectServer(SavedServer server) async {
    state = state.copyWith(
        current: server, currentPath: '', loading: true, error: null, files: []);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastServerPrefsKey, server.baseUrl);
    _client?.close();
    _client = LANdirClient(server.baseUrl, hostKey: server.hostKeyBytes);
    try {
      final files = await _client!.listDir('');
      state = state.copyWith(files: files, loading: false);
    } on ServerGoneException {
      _forgetServer(server,
          'Server ${server.name} no longer exists (404) — removed from '
          'your server list.');
      return;
    } on SealedExchangeException catch (e) {
      _forgetServer(server,
          'Server ${server.name} no longer accepts this app\'s pinned key '
          '($e) — removed from your server list. Re-scan its QR code to '
          'pair again.');
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
  /// rest of the batch. Each failure is included in the error message so a
  /// silently skipped file (e.g. a share the platform could not open) is
  /// visible instead of lost.
  Future<void> _uploadShares(List<IncomingShare> shares) async {
    var ok = 0;
    final failures = <String>[];
    for (final share in shares) {
      try {
        final Uint8List bytes;
        if (share.isText) {
          bytes = Uint8List.fromList(utf8.encode(share.text!));
        } else {
          bytes = await File(share.filePath!).readAsBytes();
        }
        if (await uploadFile(share.filename, bytes)) {
          ok++;
        } else {
          failures.add('${share.filename}: server rejected the upload');
        }
      } catch (e) {
        failures.add('${share.filename}: $e');
        state = state.copyWith(loading: false);
      }
    }
    if (ok < shares.length) {
      final detail = failures.isEmpty ? '' : ' (${failures.join('; ')})';
      state = state.copyWith(
          error: 'Uploaded $ok of ${shares.length} shared item(s)$detail');
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
      _forgetServer(current,
          'Server ${current.name} no longer exists (404) — removed from '
          'your server list.');
    } on SealedExchangeException catch (e) {
      _forgetServer(current,
          'Server ${current.name} no longer accepts this app\'s pinned key '
          '($e) — removed from your server list. Re-scan its QR code to '
          'pair again.');
    } catch (e) {
      state = state.copyWith(loading: false, error: 'Refresh failed: $e');
    }
  }

  /// The server can never answer this client again — it answered 404 (base
  /// URL no longer maps to a LANdir server) or the sealed listing no longer
  /// authenticates under the pinned key (host re-keyed, pin stale). Drop it
  /// from the registry and deselect it. [reason] is the user-facing
  /// sentence recorded in [ClientState.error] and shown by the client view.
  void _forgetServer(SavedServer server, String reason) {
    _client?.close();
    _client = null;
    _dropServer(
      server.baseUrl,
      error: reason,
      removedUrl: server.baseUrl,
      removedReason: reason,
    );
  }

  /// Remove [baseUrl] from the registry, deselect it if it is current, and
  /// persist. [error]/[removedUrl]/[removedReason] are set only when the
  /// server was dropped as unusable (see [_forgetServer]).
  void _dropServer(String baseUrl,
      {String? error, String? removedUrl, String? removedReason}) {
    final servers = state.servers.where((s) => s.baseUrl != baseUrl).toList();
    final wasCurrent = state.current?.baseUrl == baseUrl;
    if (wasCurrent) {
      SharedPreferences.getInstance().then((p) => p.remove(_lastServerPrefsKey));
    }
    state = state.copyWith(
      servers: servers,
      clearCurrent: wasCurrent,
      currentPath: wasCurrent ? '' : state.currentPath,
      files: wasCurrent ? const [] : state.files,
      loading: false,
      error: error,
      removedServerUrl: removedUrl,
      removedServerReason: removedReason,
    );
    _persistServers(servers);
  }

  /// Clear the "server removed" flag once the UI has shown it.
  void acknowledgeRemovedServer() {
    state = state.copyWith(removedServerUrl: null, removedServerReason: null);
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
