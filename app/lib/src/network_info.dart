// Network interface enumeration for finding the phone's LAN/hotspot IP.
// Pure Dart (dart:io NetworkInterface works on Android, iOS, and desktop).

import 'dart:io';

/// A candidate address the server is reachable on.
class NetworkAddress {
  final String address;
  final String interfaceName;
  final bool isHotspot;

  const NetworkAddress({
    required this.address,
    required this.interfaceName,
    this.isHotspot = false,
  });
}

/// True for addresses in the subnets commonly used by phone hotspots:
/// Android LocalOnlyHotspot (192.168.43.0/24) and iOS Personal Hotspot
/// (172.20.10.0/24).
bool _isHotspotAddress(String ip) {
  return ip.startsWith('192.168.43.') || ip.startsWith('172.20.10.');
}

bool _isPrivateAddress(String ip) {
  return ip.startsWith('10.') ||
      ip.startsWith('192.168.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\..+').hasMatch(ip);
}

/// Enumerate all IPv4 addresses on non-loopback interfaces, sorted with
/// hotspot addresses first, then other private LAN addresses.
Future<List<NetworkAddress>> findLanAddresses() async {
  final result = <NetworkAddress>[];
  for (final interface in await NetworkInterface.list(
      includeLoopback: false, type: InternetAddressType.IPv4)) {
    for (final addr in interface.addresses) {
      if (addr.isLoopback) continue;
      final ip = addr.address;
      if (!_isPrivateAddress(ip) && !_isHotspotAddress(ip)) continue;
      result.add(NetworkAddress(
        address: ip,
        interfaceName: interface.name,
        isHotspot: _isHotspotAddress(ip),
      ));
    }
  }
  result.sort((a, b) {
    if (a.isHotspot != b.isHotspot) return a.isHotspot ? -1 : 1;
    return a.address.compareTo(b.address);
  });
  return result;
}

/// Pick the best address for the QR code: prefer a hotspot address,
/// fall back to any private LAN address, then 127.0.0.1.
Future<NetworkAddress> findBestAddress() async {
  final addresses = await findLanAddresses();
  if (addresses.isNotEmpty) return addresses.first;
  return const NetworkAddress(
      address: '127.0.0.1', interfaceName: 'loopback');
}
