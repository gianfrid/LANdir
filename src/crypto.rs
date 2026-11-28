//! Sealed (encrypted) mode — the same wire protocol as the Flutter app and
//! landir.py (docs/design/001-qr-paired-app-encryption.md,
//! docs/adr/0004-cli-encrypted-mode.md): Noise-N one-way shape, fixed
//! ciphersuite X25519 ‖ HKDF-SHA256 ‖ ChaCha20-Poly1305, fresh random nonce
//! per record, no agility.
//!
//!   request envelope  (client -> host): 'L' ‖ ephPub(32) ‖ nonce(12) ‖ ct‖mac
//!   response envelope (host -> client): 'L' ‖ nonce(12) ‖ ct‖mac
//!
//! Both directions use the same DH secret but distinct HKDF info strings.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

pub const VERSION: u8 = 0x4C; // 'L'
pub const HEADER_LEN: usize = 1 + 32 + 12; // version ‖ ephPub ‖ nonce
pub const MAC_LEN: usize = 16;
const INFO_REQUEST: &[u8] = b"landir-sealed-v1-request";
const INFO_RESPONSE: &[u8] = b"landir-sealed-v1-response";

/// The long-term X25519 identity of a host (GLOSSARY: Host key), delivered
/// out-of-band via the QR fragment (`#k=`). The host stores and serves
/// plaintext by design; this is transport confidentiality, not at-rest
/// secrecy.
#[derive(Clone)]
pub struct HostKey {
    pub secret: StaticSecret,
    pub public: PublicKey,
}

pub fn host_key_from_seed(seed: [u8; 32]) -> HostKey {
    let secret = StaticSecret::from(seed);
    let public = PublicKey::from(&secret);
    HostKey { secret, public }
}

// The functions below marked `client_side` are the client half of the
// protocol: this binary is host-only (the Flutter app is the real client),
// so they exist for the test vectors / golden fixtures that prove wire
// interop — hence allow(dead_code) in non-test builds.
#[allow(dead_code)]
pub fn x25519(scalar: &[u8; 32], u: &[u8; 32]) -> [u8; 32] {
    StaticSecret::from(*scalar).diffie_hellman(&PublicKey::from(*u)).to_bytes()
}

#[allow(dead_code)]
pub fn x25519_base(scalar: &[u8; 32]) -> [u8; 32] {
    PublicKey::from(&StaticSecret::from(*scalar)).to_bytes()
}

/// X25519 shared secret with the RFC 7748 §6.1 contributory check: an
/// all-zero result (low-order / decoy public key) yields None instead of a
/// known shared secret.
fn shared_secret(secret: &StaticSecret, peer_pub: &[u8]) -> Option<[u8; 32]> {
    if peer_pub.len() != 32 {
        return None;
    }
    let mut arr = [0u8; 32];
    arr.copy_from_slice(peer_pub);
    let shared = secret.diffie_hellman(&PublicKey::from(arr));
    if shared.as_bytes().iter().all(|b| *b == 0) {
        None
    } else {
        Some(*shared.as_bytes())
    }
}

/// RFC 5869 HKDF-SHA256 with an empty (zero) salt, 32-byte output.
fn derive_key(dh: &[u8; 32], info: &[u8]) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(None, dh);
    let mut okm = [0u8; 32];
    hk.expand(info, &mut okm)
        .expect("32 bytes is a valid HKDF-SHA256 output length");
    okm
}

// The sealed envelopes use no AAD (same as the app's crypto.dart); the aad
// parameter exists so the RFC 8439 test vector (which uses AAD) can run
// through the same code path.
fn aead_encrypt(key: &[u8; 32], nonce: &[u8; 12], plaintext: &[u8], aad: &[u8]) -> Vec<u8> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    cipher
        .encrypt(Nonce::from_slice(nonce), Payload { msg: plaintext, aad })
        .expect("encryption with a fresh nonce cannot fail")
}

fn aead_decrypt(key: &[u8; 32], nonce: &[u8; 12], ct_and_mac: &[u8], aad: &[u8]) -> Option<Vec<u8>> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    cipher
        .decrypt(Nonce::from_slice(nonce), Payload { msg: ct_and_mac, aad })
        .ok()
}

/// Client side: seal `plaintext` to the pinned host key. Returns the request
/// envelope and the ephemeral seed — the caller needs the ephemeral key to
/// open the matching response. Seeds/nonces are injectable for tests.
#[allow(dead_code)]
pub fn seal_request_with(
    plaintext: &[u8],
    host_pub: &[u8; 32],
    eph_seed: &[u8; 32],
    nonce: &[u8; 12],
) -> Option<Vec<u8>> {
    let eph_pub = x25519_base(eph_seed);
    let dh = shared_secret(&StaticSecret::from(*eph_seed), host_pub)?;
    let key = derive_key(&dh, INFO_REQUEST);
    let ct = aead_encrypt(&key, nonce, plaintext, b"");
    let mut out = Vec::with_capacity(HEADER_LEN + ct.len());
    out.push(VERSION);
    out.extend_from_slice(&eph_pub);
    out.extend_from_slice(nonce);
    out.extend_from_slice(&ct);
    Some(out)
}

/// Client side with fresh random ephemeral key and nonce.
#[allow(dead_code)]
pub fn seal_request(plaintext: &[u8], host_pub: &[u8; 32]) -> Option<(Vec<u8>, [u8; 32])> {
    let mut eph_seed = [0u8; 32];
    crate::urandom_into(&mut eph_seed);
    let mut nonce = [0u8; 12];
    crate::urandom_into(&mut nonce);
    seal_request_with(plaintext, host_pub, &eph_seed, &nonce).map(|e| (e, eph_seed))
}

/// Host side: open a request envelope. Returns the plaintext, or None when
/// the envelope is malformed or the AEAD check fails (garbage/replay).
pub fn open_request(envelope: &[u8], host: &HostKey) -> Option<Vec<u8>> {
    if envelope.len() < HEADER_LEN + MAC_LEN || envelope[0] != VERSION {
        return None;
    }
    let eph_pub = &envelope[1..33];
    let nonce: [u8; 12] = envelope[33..45].try_into().ok()?;
    let dh = shared_secret(&host.secret, eph_pub)?; // low-order ephemeral: reject
    let key = derive_key(&dh, INFO_REQUEST);
    aead_decrypt(&key, &nonce, &envelope[HEADER_LEN..], b"")
}

/// Host side: seal a response for the client whose ephemeral public key
/// arrived in the request envelope. Response envelope: 'L' ‖ nonce ‖ ct‖mac.
pub fn seal_response_with(
    plaintext: &[u8],
    eph_pub: &[u8; 32],
    host: &HostKey,
    nonce: &[u8; 12],
) -> Option<Vec<u8>> {
    let dh = shared_secret(&host.secret, eph_pub)?;
    let key = derive_key(&dh, INFO_RESPONSE);
    let ct = aead_encrypt(&key, nonce, plaintext, b"");
    let mut out = Vec::with_capacity(1 + 12 + ct.len());
    out.push(VERSION);
    out.extend_from_slice(nonce);
    out.extend_from_slice(&ct);
    Some(out)
}

/// Host side with a fresh random nonce. Unreachable-None: callers only seal
/// after `open_request` accepted the envelope (which rejects low-order
/// ephemerals); fail loudly rather than seal under a zero secret.
pub fn seal_response(plaintext: &[u8], eph_pub: &[u8; 32], host: &HostKey) -> Vec<u8> {
    let mut nonce = [0u8; 12];
    crate::urandom_into(&mut nonce);
    seal_response_with(plaintext, eph_pub, host, &nonce)
        .expect("low-order ephemeral in a valid envelope")
}

/// Client side: open a response envelope given the ephemeral seed used for
/// the request and the pinned host public key. None on AEAD failure.
#[allow(dead_code)]
pub fn open_response(envelope: &[u8], eph_seed: &[u8; 32], host_pub: &[u8; 32]) -> Option<Vec<u8>> {
    if envelope.len() < 1 + 12 + MAC_LEN || envelope[0] != VERSION {
        return None;
    }
    let nonce: [u8; 12] = envelope[1..13].try_into().ok()?;
    let dh = shared_secret(&StaticSecret::from(*eph_seed), host_pub)?;
    let key = derive_key(&dh, INFO_RESPONSE);
    aead_decrypt(&key, &nonce, &envelope[13..], b"")
}

/// The ephemeral public key from a request envelope (host side).
pub fn eph_public_key_of(envelope: &[u8]) -> [u8; 32] {
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&envelope[1..33]);
    arr
}

// --- Host key persistence ---------------------------------------------------
// The key lives outside uploads/ (never served) so it survives restarts and
// app clients can pin it. Location: $LANDIR_KEY_DIR, else
// $XDG_CONFIG_HOME/landir, else ~/.config/landir, else a .landir/ dir next
// to the uploads dir (the fallback covers containers running without HOME).

pub const HOST_KEY_FILE: &str = "host_key.bin";

pub fn host_key_dir(upload_dir: &Path) -> PathBuf {
    if let Ok(d) = std::env::var("LANDIR_KEY_DIR") {
        if !d.is_empty() {
            return PathBuf::from(d);
        }
    }
    if let Ok(x) = std::env::var("XDG_CONFIG_HOME") {
        if !x.is_empty() {
            return Path::new(&x).join("landir");
        }
    }
    if let Some(h) = std::env::var_os("HOME") {
        if !h.is_empty() {
            return Path::new(&h).join(".config").join("landir");
        }
    }
    upload_dir.parent().unwrap_or(Path::new(".")).join(".landir")
}

/// Load the persisted 32-byte X25519 seed, creating and persisting one on
/// first run. A corrupt/truncated file is regenerated, not crash-looped.
pub fn load_or_create_host_key(upload_dir: &Path) -> std::io::Result<HostKey> {
    let path = host_key_dir(upload_dir).join(HOST_KEY_FILE);
    for _ in 0..2 {
        match fs::read(&path) {
            Ok(seed) if seed.len() == 32 => {
                let mut arr = [0u8; 32];
                arr.copy_from_slice(&seed);
                return Ok(host_key_from_seed(arr));
            }
            Ok(_) => {
                let _ = fs::remove_file(&path); // corrupt: regenerate below
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut seed = [0u8; 32];
        crate::urandom_into(&mut seed);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            match fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path) {
                Ok(mut f) => {
                    f.write_all(&seed)?;
                    return Ok(host_key_from_seed(seed));
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e),
            }
        }
        #[cfg(not(unix))]
        {
            match fs::OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(mut f) => {
                    f.write_all(&seed)?;
                    return Ok(host_key_from_seed(seed));
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e),
            }
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        format!("cannot establish a host key at {}", path.display()),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    fn arr32(v: &[u8]) -> [u8; 32] {
        let mut a = [0u8; 32];
        a.copy_from_slice(v);
        a
    }

    fn arr12(v: &[u8]) -> [u8; 12] {
        let mut a = [0u8; 12];
        a.copy_from_slice(v);
        a
    }

    #[test]
    fn x25519_rfc7748_vectors() {
        // RFC 7748 §5.2
        let cases = [
            ("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
             "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c",
             "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"),
            ("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d",
             "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493",
             "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"),
        ];
        for (scalar, u, expected) in cases {
            assert_eq!(
                hex(&x25519(&arr32(&unhex(scalar)), &arr32(&unhex(u)))),
                expected,
                "scalar={scalar}"
            );
        }
        // base-point multiplication
        assert_eq!(
            hex(&x25519_base(&arr32(&unhex(
                "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
            )))),
            "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
        );
    }

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    #[test]
    fn x25519_low_order_point_rejected() {
        let secret = StaticSecret::from([1u8; 32]);
        // u = 0, u = 1 and u = p-1 are genuine low-order points: the DH
        // result is all-zero and must be rejected (RFC 7748 §6.1)
        assert!(shared_secret(&secret, &[0u8; 32]).is_none());
        let mut one = [0u8; 32];
        one[0] = 1;
        assert!(shared_secret(&secret, &one).is_none());
        let mut p_minus_1 = [0xffu8; 32]; // p-1 = 2^255-20 = 0x7f..ffec LE
        p_minus_1[0] = 0xec;
        p_minus_1[31] = 0x7f;
        assert!(shared_secret(&secret, &p_minus_1).is_none());
        // malformed lengths never reach the ladder
        assert!(shared_secret(&secret, &[5u8]).is_none());
        assert!(shared_secret(&secret, &[5u8; 33]).is_none());
    }

    #[test]
    fn hkdf_sha256_rfc5869_shape() {
        // RFC 5869 test case 1, expand step: feed the known PRK through the
        // same Hkdf construction (salt is zero here, so verify the PRK and
        // OKM of the RFC case via Hkdf with an explicit salt)
        let ikm = [0x0bu8; 22];
        let salt = unhex("000102030405060708090a0b0c");
        let info = unhex("f0f1f2f3f4f5f6f7f8f9");
        let hk = Hkdf::<Sha256>::new(Some(&salt), &ikm);
        let mut okm = [0u8; 42];
        hk.expand(&info, &mut okm).unwrap();
        assert_eq!(
            hex(&okm),
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
        );
        // zero-salt path (what the envelope uses) is deterministic, 32 bytes
        let a = derive_key(&[7u8; 32], INFO_REQUEST);
        let b = derive_key(&[7u8; 32], INFO_REQUEST);
        assert_eq!(a, b);
    }

    #[test]
    fn chacha20_poly1305_rfc8439_vector() {
        // RFC 8439 §2.8.2
        let key = arr32(&unhex(
            "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f",
        ));
        let nonce = arr12(&unhex("070000004041424344454647"));
        let pt = b"Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
        let aad = unhex("50515253c0c1c2c3c4c5c6c7");
        let ct = aead_encrypt(&key, &nonce, pt, &aad);
        let expected_ct = "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116";
        let expected_mac = "1ae10b594f09e26a7e902ecbd0600691";
        assert_eq!(&hex(&ct)[..ct.len() * 2 - 32], expected_ct);
        assert_eq!(&hex(&ct)[ct.len() * 2 - 32..], expected_mac);
        assert_eq!(aead_decrypt(&key, &nonce, &ct, &aad).unwrap(), pt);
        let mut bad = ct.clone();
        let n = bad.len();
        bad[n - 1] ^= 1;
        assert!(aead_decrypt(&key, &nonce, &bad, &aad).is_none());
    }

    /// Golden fixture generated from landir.py with fixed seeds/nonces —
    /// the Python suite asserts the same hex, proving wire-format interop.
    const GOLDEN_HOST_SEED: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    const GOLDEN_EPH_SEED: &str = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f";
    const GOLDEN_REQ_NONCE: &str = "404142434445464748494a4b";
    const GOLDEN_RESP_NONCE: &str = "4c4d4e4f5051525354555657";
    const GOLDEN_HOST_PUB: &str = "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f";
    const GOLDEN_EPH_PUB: &str = "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254";
    const GOLDEN_PLAIN_REQUEST: &str = "474554202f7366696c6573207365616c65642d7265717565737420706c61696e74657874200001ff";
    const GOLDEN_PLAIN_RESPONSE: &str = "4f4b";
    const GOLDEN_REQUEST_ENVELOPE: &str = "4c358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254404142434445464748494a4ba50700f235613b0e9c31b428bdf931d3d8a49e1e61723c0b8953c0c93316a6bf92ff590ec93e4bc79ddde75311595449ee97ab76dc314ec3";
    const GOLDEN_RESPONSE_ENVELOPE: &str = "4c4c4d4e4f5051525354555657dd7a15c1f47c7d5f327d68b3c00a4190078e";

    #[test]
    fn golden_envelopes_match_python_reference() {
        let host_seed = arr32(&unhex(GOLDEN_HOST_SEED));
        let eph_seed = arr32(&unhex(GOLDEN_EPH_SEED));
        let host = host_key_from_seed(host_seed);
        assert_eq!(hex(host.public.as_bytes()), GOLDEN_HOST_PUB);
        assert_eq!(hex(&x25519_base(&eph_seed)), GOLDEN_EPH_PUB);

        let req = seal_request_with(
            &unhex(GOLDEN_PLAIN_REQUEST),
            host.public.as_bytes(),
            &eph_seed,
            &arr12(&unhex(GOLDEN_REQ_NONCE)),
        )
        .unwrap();
        assert_eq!(hex(&req), GOLDEN_REQUEST_ENVELOPE);

        let resp = seal_response_with(
            &unhex(GOLDEN_PLAIN_RESPONSE),
            &arr32(&unhex(GOLDEN_EPH_PUB)),
            &host,
            &arr12(&unhex(GOLDEN_RESP_NONCE)),
        )
        .unwrap();
        assert_eq!(hex(&resp), GOLDEN_RESPONSE_ENVELOPE);

        // and they open back
        assert_eq!(
            open_request(&unhex(GOLDEN_REQUEST_ENVELOPE), &host).unwrap(),
            unhex(GOLDEN_PLAIN_REQUEST)
        );
        assert_eq!(
            open_response(&unhex(GOLDEN_RESPONSE_ENVELOPE), &eph_seed, host.public.as_bytes())
                .unwrap(),
            unhex(GOLDEN_PLAIN_RESPONSE)
        );
    }

    #[test]
    fn envelope_round_trip_and_tamper() {
        let mut seed = [0u8; 32];
        crate::urandom_into(&mut seed);
        let host = host_key_from_seed(seed);
        let (env, eph_seed) = seal_request(b"round trip \x00\xff", host.public.as_bytes()).unwrap();
        assert_eq!(open_request(&env, &host).unwrap(), b"round trip \x00\xff");
        let resp = seal_response(b"pong", &eph_public_key_of(&env), &host);
        assert_eq!(open_response(&resp, &eph_seed, host.public.as_bytes()).unwrap(), b"pong");
        // tampered header / ciphertext / mac all fail
        for pos in [0, 10, env.len() - 1] {
            let mut bad = env.clone();
            bad[pos] ^= 1;
            assert!(open_request(&bad, &host).is_none(), "tamper at {pos}");
        }
        assert!(open_request(&env[..env.len() - 5], &host).is_none());
        assert!(open_request(b"garbage", &host).is_none());
        assert!(open_request(b"", &host).is_none());
        // a different host key cannot open it
        let other = host_key_from_seed([7u8; 32]);
        assert!(open_request(&env, &other).is_none());
    }

    #[test]
    fn host_key_persistence_and_corruption() {
        let dir = std::env::temp_dir().join(format!(
            "landir-crypto-test-{}-{:x}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let key1 = load_or_create_host_key(&dir).unwrap();
        let key2 = load_or_create_host_key(&dir).unwrap();
        assert_eq!(key1.public.as_bytes(), key2.public.as_bytes()); // stable
        let path = host_key_dir(&dir).join(HOST_KEY_FILE);
        fs::write(&path, b"short").unwrap(); // corrupt: regenerated
        let key3 = load_or_create_host_key(&dir).unwrap();
        assert_ne!(key3.public.as_bytes(), key1.public.as_bytes());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        let _ = fs::remove_dir_all(&dir);
    }
}
