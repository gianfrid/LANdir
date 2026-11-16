// Tests for isLanHost: the classifier gating the non-LAN server warning.
// Landir is LAN-only; anything not clearly local must classify as false so
// the client warns before sending file bytes to it.

import 'package:flutter_test/flutter_test.dart';
import 'package:landir_app/src/core/security.dart';

void main() {
  group('isLanHost accepts LAN-consistent hosts', () {
    test('private IPv4 ranges', () {
      expect(isLanHost('10.0.0.9'), isTrue);
      expect(isLanHost('10.1.2.3'), isTrue);
      expect(isLanHost('192.168.1.50'), isTrue);
      expect(isLanHost('172.16.0.1'), isTrue);
      expect(isLanHost('172.31.255.254'), isTrue);
    });

    test('loopback and link-local', () {
      expect(isLanHost('127.0.0.1'), isTrue);
      expect(isLanHost('169.254.1.1'), isTrue); // IPv4 link-local
      expect(isLanHost('localhost'), isTrue);
      expect(isLanHost('::1'), isTrue);
      expect(isLanHost('fe80::1234'), isTrue); // IPv6 link-local
    });

    test('LAN hostnames', () {
      expect(isLanHost('phone'), isTrue); // single label
      expect(isLanHost('landir-box.local'), isTrue); // mDNS
      expect(isLanHost('PHONE'), isTrue); // case-insensitive
    });
  });

  group('isLanHost rejects non-LAN hosts', () {
    test('public IPv4', () {
      expect(isLanHost('8.8.8.8'), isFalse);
      expect(isLanHost('1.1.1.1'), isFalse);
      expect(isLanHost('203.0.113.7'), isFalse); // TEST-NET-3
    });

    test('malformed or out-of-range IPv4', () {
      expect(isLanHost('192.168.1.999'), isFalse);
      expect(isLanHost('10.0.0'), isFalse); // not 4 octets
    });

    test('172 outside the private second-octet range', () {
      // 172.32+ is public; only 172.16-31 is private.
      expect(isLanHost('172.32.0.1'), isFalse);
      expect(isLanHost('172.15.0.1'), isFalse);
    });

    test('multi-label DNS names', () {
      expect(isLanHost('evil.example.com'), isFalse);
      expect(isLanHost('files.example.org'), isFalse);
      // .local is trusted, but a public-looking suffix is not:
      expect(isLanHost('host.local.example.com'), isFalse);
    });

    test('public IPv6 (global unicast)', () {
      expect(isLanHost('2001:db8::1'), isFalse);
      expect(isLanHost('2606:4700::1111'), isFalse);
    });

    test('empty', () {
      expect(isLanHost(''), isFalse);
      expect(isLanHost('   '), isFalse);
    });
  });
}
