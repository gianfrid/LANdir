// Local registry of files this app has downloaded, persisted in
// shared_preferences. On Android the bytes live in MediaStore.Downloads;
// on iOS/desktop in the app Documents directory. The registry tracks what
// the app itself saved so the UI can list and re-open them.

import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

const String _downloadsPrefsKey = 'landir_local_downloads';

/// One locally downloaded file.
class LocalDownload {
  final String name;
  final int timestamp; // ms since epoch

  const LocalDownload({required this.name, required this.timestamp});

  Map<String, dynamic> toJson() => {'name': name, 'timestamp': timestamp};

  factory LocalDownload.fromJson(Map<String, dynamic> j) => LocalDownload(
        name: j['name'] as String,
        timestamp: (j['timestamp'] as num).toInt(),
      );
}

Future<List<LocalDownload>> listLocalDownloads() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_downloadsPrefsKey);
  if (raw == null) return [];
  try {
    final list = (jsonDecode(raw) as List<dynamic>)
        .map((e) => LocalDownload.fromJson(e as Map<String, dynamic>))
        .toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  } catch (_) {
    return [];
  }
}

/// Record a successful download. Deduplicates by name, keeps newest first.
Future<void> recordDownload(String name) async {
  final prefs = await SharedPreferences.getInstance();
  final existing = await listLocalDownloads();
  final updated = [
    LocalDownload(name: name, timestamp: DateTime.now().millisecondsSinceEpoch),
    ...existing.where((d) => d.name != name),
  ];
  await prefs.setString(
      _downloadsPrefsKey, jsonEncode(updated.map((d) => d.toJson()).toList()));
}

/// Remove an entry from the local registry (the file itself stays in
/// MediaStore/Documents unless deleted there).
Future<void> forgetDownload(String name) async {
  final prefs = await SharedPreferences.getInstance();
  final existing = await listLocalDownloads();
  final updated = existing.where((d) => d.name != name).toList();
  await prefs.setString(
      _downloadsPrefsKey, jsonEncode(updated.map((d) => d.toJson()).toList()));
}

/// Whether the platform can open files via intent (Android only).
bool get canOpenFiles => Platform.isAndroid;
