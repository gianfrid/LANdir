// QR-paired encryption primitives — implementation of the deferred design
// docs/design/001-qr-paired-app-encryption.md (milestones M1/M2/M4).
//
// Pure Dart (package:cryptography only, zero platform channels) so
// client.dart/server.dart stay Flutter-free.
//
// Construction (Noise-N one-way shape, fixed ciphersuite, no agility):
//   client ephemeral X25519 ‖ HKDF-SHA256 ‖ AEAD ChaCha20-Poly1305,
//   fresh random nonce per record.
//
// Request envelope  (client -> host):  'L' ‖ ephPub(32) ‖ nonce(12) ‖ ct+mac
// Response envelope (host -> client):  'L' ‖ nonce(12) ‖ ct+mac
// The two directions use the same DH secret but distinct HKDF info strings.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int _hostKeyLength = 32; // X25519 public key
const int _nonceLength = 12; // ChaCha20-Poly1305
const int _macLength = 16;
const int _version = 0x4c; // 'L'

const String _hkdfInfoRequest = 'landir-sealed-v1-request';
const String _hkdfInfoResponse = 'landir-sealed-v1-response';

final X25519 _x25519 = X25519();
final _aead = Chacha20.poly1305Aead();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

void _fillSecureRandom(Uint8List bytes) {
  final rng = Random.secure();
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = rng.nextInt(256);
  }
}

/// The long-term X25519 identity of a host (GLOSSARY: Host key), delivered
/// out-of-band via the QR fragment.
class HostKey {
  final SimpleKeyPair keyPair;
  final Uint8List publicKey; // 32 bytes

  HostKey(this.keyPair, this.publicKey);
}

/// Generates, persists, and loads the host key in [dirPath] — the app-support
/// directory, never under uploads/. The persisted form is the 32-byte
/// private seed; the host stores and serves plaintext by design, so this is
/// transport confidentiality, not at-rest secrecy.
class HostKeyStore {
  final String dirPath;

  static const String fileName = 'host_key.bin';

  const HostKeyStore(this.dirPath);

  File get _file => File('$dirPath/$fileName');

  Future<HostKey> loadOrCreate() async {
    final file = _file;
    if (file.existsSync()) {
      final seed = await file.readAsBytes();
      if (seed.length == _hostKeyLength) {
        return _fromSeed(seed);
      }
      // Corrupt/truncated file: regenerate rather than crash-loop.
    }
    final seed = Uint8List(_hostKeyLength);
    _fillSecureRandom(seed);
    await Directory(dirPath).create(recursive: true);
    await file.writeAsBytes(seed, flush: true);
    return _fromSeed(seed);
  }

  Future<HostKey> _fromSeed(List<int> seed) async {
    final keyPair = await _x25519.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    return HostKey(keyPair, Uint8List.fromList(publicKey.bytes));
  }
}

/// Maximum byte-mode payload of the QR encoder used by the app (version 6,
/// EC level M = 106 bytes). The advertised URL must fit or the QR is
/// unscannable.
const int qrMaxUrlBytes = 106;

/// Builds the advertised URL with the host key in the fragment:
/// `http://ip:port/<token>/#k=<base64url(pubkey)>` (padding stripped).
///
/// Returns null when the URL would exceed the QR capacity — the caller must
/// warn and fall back to the keyless URL rather than truncate key material.
String? advertisedUrlWithKey(
    String address, int port, String? token, Uint8List hostPublicKey) {
  final k = base64Url.encode(hostPublicKey).replaceAll('=', '');
  final url =
      'http://$address:$port${token != null ? '/$token/' : '/'}#k=$k';
  if (utf8.encode(url).length > qrMaxUrlBytes) return null;
  return url;
}

/// Splits a scanned URL into its base URL (no fragment) and the pinned host
/// key, if the `#k=` fragment is present and well-formed. A malformed `#k=`
/// yields a null key, never an exception: keyless hosts are valid.
({String baseUrl, Uint8List? hostKey}) parsePairedUrl(String raw) {
  final uri = Uri.parse(raw.trim());
  var base = uri.replace(fragment: '').toString();
  if (base.endsWith('#')) base = base.substring(0, base.length - 1);
  final baseUrl = base.endsWith('/') ? base : '$base/';
  final frag = uri.fragment;
  Uint8List? key;
  if (frag.startsWith('k=')) {
    try {
      final decoded = base64Url.decode(_pad(frag.substring(2)));
      if (decoded.length == _hostKeyLength) key = Uint8List.fromList(decoded);
    } catch (_) {
      key = null;
    }
  }
  return (baseUrl: baseUrl, hostKey: key);
}

String _pad(String s) {
  final rem = s.length % 4;
  return rem == 0 ? s : s + '=' * (4 - rem);
}

/// Restores stripped base64url padding (see advertisedUrlWithKey).
String padBase64Url(String s) => _pad(s);

/// X25519 shared secret with the Noise contributory check: an all-zero
/// result (low-order / decoy public key, RFC 7748 §6.1) yields null instead
/// of a key, so a crafted low-order envelope cannot force a known shared
/// secret. The construction is Noise-N-shaped and stays that way.
Future<Uint8List?> _sharedSecret(SimpleKeyPair kp, Uint8List remotePub) async {
  final dh = await _x25519.sharedSecretKey(
    keyPair: kp,
    remotePublicKey: SimplePublicKey(remotePub, type: KeyPairType.x25519),
  );
  final bytes = await dh.extractBytes();
  if (bytes.every((b) => b == 0)) return null;
  return Uint8List.fromList(bytes);
}

Future<SecretKey> _deriveKey(Uint8List dh, String info) async {
  final key = await _hkdf.deriveKey(
    secretKey: SecretKey(dh),
    nonce: const [],
    info: utf8.encode(info),
  );
  return SecretKey(key.bytes);
}

Uint8List _randomNonce() {
  final nonce = Uint8List(_nonceLength);
  _fillSecureRandom(nonce);
  return nonce;
}

/// Seals [plaintext] to the host identified by [hostPublicKey] (client side).
/// Returns the request envelope ('L' ‖ ephPub(32) ‖ nonce(12) ‖ ct+mac) and
/// the ephemeral key pair it used — the caller needs that pair to open the
/// matching response with [openResponse].
Future<({Uint8List envelope, SimpleKeyPair ephKeyPair})> sealToHost(
    Uint8List plaintext, Uint8List hostPublicKey) async {
  final eph = await _x25519.newKeyPair();
  final ephPub = await eph.extractPublicKey();
  final dh = await _sharedSecret(eph, hostPublicKey);
  // The pinned host key is a low-order point: there is no honest key
  // exchange to have. Fail loudly — callers show an error, never plaintext.
  if (dh == null) throw ArgumentError('pinned host key is a low-order point');
  final key = await _deriveKey(dh, _hkdfInfoRequest);
  final nonce = _randomNonce();
  final box = await _aead.encrypt(plaintext, secretKey: key, nonce: nonce);
  final out = Uint8List(1 + 32 + _nonceLength + box.cipherText.length + _macLength);
  var o = 0;
  out[o++] = _version;
  out.setRange(o, o + 32, ephPub.bytes);
  o += 32;
  out.setRange(o, o + _nonceLength, nonce);
  o += _nonceLength;
  out.setRange(o, o + box.cipherText.length, box.cipherText);
  o += box.cipherText.length;
  out.setRange(o, o + _macLength, box.mac.bytes);
  return (envelope: out, ephKeyPair: eph);
}

/// Opens a request envelope at the host. Returns the plaintext, or null when
/// the envelope is malformed or the AEAD check fails (garbage/replay).
Future<Uint8List?> openAtHost(Uint8List envelope, HostKey host) async {
  const header = 1 + 32 + _nonceLength;
  if (envelope.length < header + _macLength || envelope[0] != _version) {
    return null;
  }
  final ephPub = Uint8List.sublistView(envelope, 1, 1 + 32);
  final nonce = Uint8List.sublistView(envelope, 33, 33 + _nonceLength);
  final ctLen = envelope.length - header - _macLength;
  final box = SecretBox(
    Uint8List.sublistView(envelope, header, header + ctLen),
    nonce: nonce,
    mac: Mac(Uint8List.sublistView(envelope, header + ctLen)),
  );
  final dh = await _sharedSecret(host.keyPair, ephPub);
  if (dh == null) return null; // low-order ephemeral: reject the envelope
  final key = await _deriveKey(dh, _hkdfInfoRequest);
  try {
    final clear = await _aead.decrypt(box, secretKey: key);
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    return null;
  }
}

/// Seals a response for the client whose ephemeral public key arrived in the
/// request envelope (host side). Response envelope: 'L' ‖ nonce(12) ‖ ct+mac.
Future<Uint8List> sealResponse(
    Uint8List plaintext, Uint8List ephPublicKey, HostKey host) async {
  final dh = await _sharedSecret(host.keyPair, ephPublicKey);
  // Null is unreachable here: _handleSealedPost only seals responses after
  // openAtHost accepted the envelope (which already rejects low-order
  // ephemerals). Fail loudly rather than seal under a zero secret.
  if (dh == null) throw StateError('low-order ephemeral in a valid envelope');
  final key = await _deriveKey(dh, _hkdfInfoResponse);
  final nonce = _randomNonce();
  final box = await _aead.encrypt(plaintext, secretKey: key, nonce: nonce);
  final out = Uint8List(1 + _nonceLength + box.cipherText.length + _macLength);
  var o = 0;
  out[o++] = _version;
  out.setRange(o, o + _nonceLength, nonce);
  o += _nonceLength;
  out.setRange(o, o + box.cipherText.length, box.cipherText);
  o += box.cipherText.length;
  out.setRange(o, o + _macLength, box.mac.bytes);
  return out;
}

/// Opens a response envelope at the client, given the ephemeral key pair the
/// client used for the request and the pinned host public key. Returns null
/// on AEAD failure (a MITM cannot forge or strip responses: the framing
/// decision happened at scan time, off-network).
Future<Uint8List?> openResponse(Uint8List envelope, SimpleKeyPair ephKeyPair,
    Uint8List hostPublicKey) async {
  const header = 1 + _nonceLength;
  if (envelope.length < header + _macLength || envelope[0] != _version) {
    return null;
  }
  final nonce = Uint8List.sublistView(envelope, 1, header);
  final ctLen = envelope.length - header - _macLength;
  final box = SecretBox(
    Uint8List.sublistView(envelope, header, header + ctLen),
    nonce: nonce,
    mac: Mac(Uint8List.sublistView(envelope, header + ctLen)),
  );
  final dh = await _sharedSecret(ephKeyPair, hostPublicKey);
  if (dh == null) return null;
  final key = await _deriveKey(dh, _hkdfInfoResponse);
  try {
    final clear = await _aead.decrypt(box, secretKey: key);
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    return null;
  }
}

/// Extracts the ephemeral public key from a request envelope, so the host
/// can seal its response to that exact ephemeral (host side, M2).
Uint8List ephPublicKeyOf(Uint8List envelope) =>
    Uint8List.sublistView(envelope, 1, 1 + 32);
