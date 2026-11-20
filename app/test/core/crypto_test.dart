// Tests for core/crypto.dart: RFC 7748 X25519 vectors, RFC 5869 HKDF
// vectors, a committed golden sealed envelope, and key-store / URL round
// trips (design milestones M1/M2).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:landir_app/src/core/crypto.dart';
import 'package:test/test.dart';

Uint8List hex(String s) => Uint8List.fromList(List.generate(
    s.length ~/ 2, (i) => int.parse(s.substring(2 * i, 2 * i + 2), radix: 16)));

String toHex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('RFC 7748 X25519 vectors', () {
    test('public keys and shared secret match the RFC', () async {
      final alice = await _keyFromSeed(
          '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
      final bob = await _keyFromSeed(
          '5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb');
      expect(toHex(alice.publicKey),
          '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a');
      expect(toHex(bob.publicKey),
          'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f');
      final shared = await _x25519Shared(alice, bob);
      expect(toHex(shared),
          '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742');
    });
  });

  group('RFC 5869 HKDF-SHA256 vectors', () {
    test('test case 1 OKM matches the RFC', () async {
      final okm = await _rfc5869Case1();
      expect(okm,
          '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
          '34007208d5b887185865');
    });
  });

  group('golden sealed envelope (committed fixture)', () {
    // Fixed host seed 01*32, fixed ephemeral seed 02*32, fixed nonce
    // 000102..0b, plaintext "hello landir".
    const hostPub =
        'a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209';
    const envelope =
        '4cce8d3ad1ccb633ec7b70c17814a5c76ecd029685050d344745ba05870e587d59'
        '000102030405060708090a0b'
        '8e374caeb747f97d5e8767900f39564b95e398009b997b313b10d694';

    test('opens to the expected plaintext', () async {
      final host = await _keyFromSeed('01' * 32);
      expect(toHex(host.publicKey), hostPub);
      final opened = await openAtHost(hex(envelope), host);
      expect(opened, isNotNull);
      expect(utf8.decode(opened!), 'hello landir');
    });

    test('tampered ciphertext fails AEAD and returns null', () async {
      final host = await _keyFromSeed('01' * 32);
      final tampered = hex(envelope);
      tampered[tampered.length - 3] ^= 0x01;
      expect(await openAtHost(tampered, host), isNull);
    });

    test('wrong host key fails AEAD and returns null', () async {
      final wrongHost = await _keyFromSeed('ff' * 32);
      expect(await openAtHost(hex(envelope), wrongHost), isNull);
    });

    test('truncated envelope returns null', () async {
      final host = await _keyFromSeed('01' * 32);
      expect(await openAtHost(hex(envelope).sublist(0, 20), host), isNull);
    });

    test('low-order ephemeral (all-zero DH) is rejected by the guard',
        () async {
      final host = await _keyFromSeed('01' * 32);
      // Encrypt under the key an all-zero shared secret would derive, so
      // only the contributory check — not an AEAD failure — can reject
      // this envelope (u=0 and u=1 are low-order Curve25519 points).
      final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
          .deriveKey(
              secretKey: SecretKey(Uint8List(32)),
              nonce: const [],
              info: utf8.encode('landir-sealed-v1-request'));
      final box = await Chacha20.poly1305Aead()
          .encrypt(utf8.encode('sneaky'), secretKey: key, nonce: Uint8List(12));
      final ephPub = Uint8List(32)..[0] = 1;
      final env = Uint8List(1 + 32 + 12 + box.cipherText.length + 16);
      env[0] = 0x4c;
      env.setRange(1, 33, ephPub);
      env.setRange(33, 45, box.nonce);
      env.setRange(45, 45 + box.cipherText.length, box.cipherText);
      env.setRange(env.length - 16, env.length, box.mac.bytes);
      expect(await openAtHost(env, host), isNull);
    });
  });

  group('seal/open round trips', () {
    test('request -> response round trip', () async {
      final host = await _keyFromSeed('aa' * 32);
      final req = await sealToHost(utf8.encode('ping'), host.publicKey);
      final opened = await openAtHost(req.envelope, host);
      expect(utf8.decode(opened!), 'ping');
      final resp = await sealResponse(
          utf8.encode('pong'), ephPublicKeyOf(req.envelope), host);
      final openedResp =
          await openResponse(resp, req.ephKeyPair, host.publicKey);
      expect(utf8.decode(openedResp!), 'pong');
    });

    test('response does not open under the request direction', () async {
      final host = await _keyFromSeed('bb' * 32);
      final req = await sealToHost(utf8.encode('x'), host.publicKey);
      final resp = await sealResponse(
          utf8.encode('y'), ephPublicKeyOf(req.envelope), host);
      // Feeding a response envelope to the request opener must fail.
      expect(await openAtHost(resp, host), isNull);
    });
  });

  group('HostKeyStore (M1)', () {
    test('round-trips the same key across store instances', () async {
      final dir = Directory.systemTemp.createTempSync('landir_keystore_');
      try {
        final store = HostKeyStore(dir.path);
        final first = await store.loadOrCreate();
        final second = await HostKeyStore(dir.path).loadOrCreate();
        expect(toHex(second.publicKey), toHex(first.publicKey));
        expect(File('${dir.path}/${HostKeyStore.fileName}').existsSync(), isTrue);
        // Key file must never live under uploads/
        expect(dir.path.contains('uploads'), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('advertised URL with #k= (M1)', () {
    test('builds fragment URL and parses it back', () async {
      final host = await _keyFromSeed('cc' * 32);
      final url = advertisedUrlWithKey('192.168.1.10', 8000, 'tok123', host.publicKey);
      expect(url, isNotNull);
      expect(url, startsWith('http://192.168.1.10:8000/tok123/#k='));
      final parsed = parsePairedUrl(url!);
      expect(parsed.baseUrl, 'http://192.168.1.10:8000/tok123/');
      expect(toHex(parsed.hostKey!), toHex(host.publicKey));
    });

    test('refuses (null) when the URL exceeds QR capacity instead of truncating', () async {
      final host = await _keyFromSeed('dd' * 32);
      // A very long host + long token pushes the URL past 106 bytes.
      final longHost = 'fe80::1234:5678:9abc:def0%verylonginterface0123456789';
      final url = advertisedUrlWithKey(
          longHost, 60999, 'abcdefghijklmnopqrstuvwxyz0123456789', host.publicKey);
      expect(url, isNull);
    });

    test('keyless URL parses with null host key', () {
      final parsed = parsePairedUrl('http://192.168.1.5:8000/abc/');
      expect(parsed.baseUrl, 'http://192.168.1.5:8000/abc/');
      expect(parsed.hostKey, isNull);
    });

    test('malformed #k= yields null key, not an exception', () {
      final parsed = parsePairedUrl('http://10.0.0.2:8000/#k=!!!notbase64!!!');
      expect(parsed.hostKey, isNull);
    });
  });
}

Future<HostKey> _keyFromSeed(String seedHex) async {
  final dir = Directory.systemTemp.createTempSync('landir_key_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/${HostKeyStore.fileName}');
  await file.writeAsBytes(hex(seedHex));
  return HostKeyStore(dir.path).loadOrCreate();
}

Future<List<int>> _x25519Shared(HostKey a, HostKey b) async {
  final x = X25519();
  final dh = await x.sharedSecretKey(
    keyPair: a.keyPair,
    remotePublicKey: SimplePublicKey(b.publicKey, type: KeyPairType.x25519),
  );
  return dh.extractBytes();
}

Future<String> _rfc5869Case1() async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 42);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(hex('0b' * 22)),
    nonce: hex('000102030405060708090a0b0c'),
    info: hex('f0f1f2f3f4f5f6f7f8f9'),
  );
  return toHex(key.bytes);
}
