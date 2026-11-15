// LocalOnlyHotspot on Android API 30+: requests a local-only WiFi hotspot
// that needs no location permission. On iOS or older Android, returns null
// and the UI guides the user to enable a hotspot manually.

import 'dart:io' show Platform;

import '../platform_channels.dart';

/// Result of a LocalOnlyHotspot request.
class HotspotResult {
  final String? ssid;
  final String? gatewayIp;

  const HotspotResult({this.ssid, this.gatewayIp});
}

/// Request a LocalOnlyHotspot. Returns null on non-Android or API < 30.
Future<HotspotResult?> requestLocalOnlyHotspot() async {
  if (!Platform.isAndroid) return null;
  try {
    final result = await hotspotChannel.invokeMethod<Map<dynamic, dynamic>>(
        'startLocalOnlyHotspot');
    if (result == null) return null;
    return HotspotResult(
      ssid: result['ssid'] as String?,
      gatewayIp: result['gatewayIp'] as String?,
    );
  } catch (_) {
    return null;
  }
}
