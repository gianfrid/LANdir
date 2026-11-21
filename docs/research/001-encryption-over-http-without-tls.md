# 001 — Encrypting data over plain HTTP without TLS, with MITM resistance

Research question: how can data sent over plain HTTP be encrypted
(application-layer, no TLS) while remaining resistant to man-in-the-middle
(MITM) attacks — in general, and for LANdir specifically (stock-browser LAN
file sharing where the host displays a QR code of a tokenized capability URL).

Status: research only; no code change is proposed here.

## TL;DR

Encryption without TLS is easy; **authentication** without TLS is the whole
problem. An unauthenticated key exchange is transparently MITM-able, and
every serious scheme reduces to one of three authentication sources:
a pre-shared secret, a third-party-certified key (what TLS does), or
out-of-band verification / trust-on-first-use (RFC 4251 §4.1 [5]; Noise
§14 [7]). LANdir is unusually well positioned for the third source: it already
owns a genuine out-of-band channel — the QR code — but that channel currently
carries only a bearer capability token, which authenticates nothing about the
connection and is itself readable off the wire by anyone who can observe the
session.

The honest finding for the browser client is negative: a plain-HTTP server
serves the JavaScript that would do the encrypting, so an active first-use
MITM can replace it, and no web-platform mechanism (SRI, ETag, cache pinning,
fragment key) authenticates first-load JS over plain HTTP — the SRI spec says
so itself (§5.1) [21]. Worse: `crypto.subtle` is `[SecureContext]`-gated
(WebCrypto IDL [19]) and a plain `http://` origin on a LAN IP is *not* a
secure context (Secure Contexts §3.1 [20]), so stock Chrome/Firefox expose no
WebCrypto at all on LANdir's page as it runs today.

Recommendation (option d, hybrid): real end-to-end sealing inside the Flutter
app — which ships its own crypto code in the binary and thus sidesteps the
JS-delivery problem — keyed by an X25519 public key appended to the QR code /
URL fragment; plus opportunistic JS-side sealing for browsers as a defense
against the passive LAN observer only, labeled as such. Against an active
first-use MITM the browser story cannot be fixed and should be documented as
a known limitation of the plain-HTTP browser contract, with the reverse-proxy
TLS path (README) as the real upgrade.

## 1. Why this is hard: the authentication problem

"MITM resistance" formally means an **authenticated key exchange (AKE)**: the
parties derive a shared key *and* each gains evidence that the key is shared
with the intended peer, not with an interceptor running two parallel
exchanges. Diffie–Hellman alone gives confidentiality against passive
observers and nothing against an active attacker, who simply exchanges keys
separately with both sides.

The Noise framework states the resulting requirement exactly: a protocol with
static keys "verifies that the corresponding private keys are possessed by the
participant(s), but it's up to the application to determine whether the remote
party's static public key is acceptable. Methods for doing so include
certificates which sign the public key..., preconfigured lists of public
keys, or 'pinning'/'key-continuity' approaches" (Noise §14, Authentication)
[7]. SSH's architecture RFC lays out the same families and prices the third:
SSH "provides the option that the server name–host key association is not
checked when connecting to the host for the first time... The connection still
provides protection against passive listening; however, it becomes vulnerable
to active man-in-the-middle attacks. Implementations SHOULD NOT normally
allow such connections by default" — with key fingerprints as the out-of-band
remedy, "verified by using telephone or other external communication channels"
(RFC 4251 §4.1; the three MITM cases are walked through in §9.3.4) [5].

So the design space is: **pre-shared secret/password, PKI, or out-of-band
verification (TOFU)**. Everything below is an instance of one of these, and
any "MITM-proof crypto without TLS" marketing claim reduces to one of them —
usually TOFU with its first-use window undeclared.

## 2. PAKE: keys from low-entropy shared secrets

PAKE lets two parties sharing only a weak secret derive a strong key, with
the property that an active MITM gets exactly **one guess** at the secret per
protocol run and both sides detect a failed guess. SRP promises exactly this:
"protection against both passive and active attacks" with "trusted key servers
and certificate infrastructures... not required" (RFC 2945 abstract; §1 also
works through the dictionary attacks that break naive challenge–response
schemes like RFC 2095's) [1].

The modern CFRG family — what to use today:

- **SPAKE2** (RFC 9382): symmetric PAKE (both sides hold a password
  equivalent); security proof reduces to the GDH assumption. The RFC itself
  flags the limitation: "SPAKE2 does not support augmentation. As a result,
  the server has to store a password equivalent... Applications that need
  augmented PAKEs should use [OPAQUE]"; received group elements MUST be
  validated for group membership (RFC 9382 §7) [2].
- **SPAKE2+** (RFC 9383): augmented variant (server stores only a verifier)
  with a proper HKDF schedule and key confirmation (§3.4, §6) [3].
- **OPAQUE** (RFC 9807 — note: **not** RFC 9380, which is Hashing to
  Elliptic Curves; the RFC index confirms OPAQUE is RFC 9807, published
  July 2025 [4]): the CFRG-selected aPAKE, "supports mutual authentication in
  a client-server setting without reliance on PKI and with security against
  pre-computation attacks upon server compromise", plus forward secrecy and
  password hiding during registration (RFC 9807 abstract) [4].

*What this buys / what this costs.* PAKE converts "share a short secret over
a side channel" into "mutually authenticated session key" — no infrastructure.
Costs: (1) the secret's entropy is the attacker's per-run online guess budget
(no offline dictionary is possible against SPAKE2 — that is the whole point);
(2) with a symmetric PAKE the server stores a password equivalent — harmless
when the "password" is a random per-run key rather than a human one, which is
exactly the wormhole/LANdir shape, making OPAQUE's augmentation unnecessary
here; (3) PAKE only authenticates — a well-engineered AEAD record layer on
top is still required, and bespoke constructions invite the rollback and
negotiation bugs Noise §14 warns about [7].

## 3. TOFU / out-of-band verification precedents

- **SSH host keys** (RFC 4251): accept-on-first-use with local key continuity
  and scary change warnings is the canonical TOFU; the RFC explicitly grades
  it below verification and reserves SHOULD NOT for silent acceptance [5].
  The usability-vs-first-connect-MITM tradeoff is the acknowledged cost.
- **Signal safety numbers**: Signal derives per-chat verification values
  (digits / QR), and its own documentation is blunt that displaying them
  "does not verify anyone's identity" — safety number changes generate
  warnings that "help protect against any attempted man-in-the-middle
  attacks," but the root of trust is the humans comparing them out of band,
  ideally "by scanning your contact's QR code (in person)" (Signal support
  [13]); the send side blocks or requires manual approval before encrypting
  to a changed key (Signal blog [14]).
- **WireGuard**: "Short pre-shared static keys—Curve25519 points—are used for
  mutual authentication in the style of OpenSSH", while "WireGuard's attitude
  toward key distribution is that this is the wrong layer to address that
  particular problem" — keys are distributed however the operator likes
  (config push, QR, USB), and the NoiseIK handshake then guarantees an active
  MITM "would not be able to decrypt or modify any payload, which merely
  amounts to a denial-of-service attack" (WireGuard paper §1, §4; §5.2 adds an
  optional PSK to the mix) [6].
- **Noise framework**: the XX pattern (`-> e / <- e,ee,s,es / -> s,se`)
  transmits both static keys inside the handshake, so mutual authentication
  holds only as strongly as the way each static key is then verified; XX
  with no verification is "SSH without known_hosts" (Noise §7.5) [7].
- **CurveCP (djb)**: MITM resistance by assumption, stated upfront: "The
  client knows the server's long-term public key in advance, before making a
  CurveCP connection. ... An attacker with full control over every packet
  between the client and server can compromise availability but cannot
  compromise confidentiality or integrity" (curvecp.org, Confidentiality and
  integrity; the Addressing page: before connecting, the client needs "(1)
  the server's long-term public key and (2) the server's address") [8]. djb
  deliberately chose pre-known keys, no PKI, and no cipher agility; the same
  safety-in-simplicity argument (no secret-dependent control flow,
  centralized randomness, conservative primitives) drives NaCl in the
  Bernstein–Lange–Schwabe "security impact" paper [9].

*What this buys / what this costs.* Key continuity plus out-of-band
comparison gives strong practical MITM resistance with zero infrastructure,
backed by decades of SSH usage. The costs: a first-use window (TOFU) or a
human comparison step (Signal), and — decisive for LANdir — **the integrity
of the comparison channel becomes the security perimeter**. If the fingerprint
is displayed to users by the very path it is supposed to verify, the scheme is
circular; if it arrives via a genuinely separate channel (in-person scan,
host's own screen), it has a root of trust on day one without any TOFU window.

## 4. Short-code file transfer: the nearest precedents

- **magic-wormhole** (Brian Warner): a short code feeds SPAKE2 — the `pake`
  phase carries the SPAKE2 message "computed as X+M*pw or Y+N*pw" — over a
  rendezvous server; everything after runs as NaCl SecretBox records with
  per-phase keys via HKDF-SHA256, and a `wormhole:verifier` subkey is
  displayed to users, which "protects against the threat where a man in the
  middle attacker correctly guesses the password" (client-protocol.md [10];
  architecture in introduction.rst [12]). The project's own threat-model doc
  quantifies the margin: default wormhole codes carry **16 bits** of entropy,
  an attacker positioned on the network gets one 1-in-65536 guess, and "an
  attacker who learns your secret wormhole code directly (because you
  delivered it over an insecure channel) can perform this attack with 100%
  reliability" (attacks.rst [11]). The short code *is* the entire
  authentication story.
- **croc**: same shape — "The code phrase is used to establish
  password-authenticated key agreement (PAKE) which generates a secret key
  for the sender and recipient to use for end-to-end encryption" (README)
  [15], implemented via the author's `schollz/pake` library, a "PAKE2"
  protocol taken from Boneh–Shoup's cryptography book and built "so I could
  use PAKE in my file-transfer utility, croc" [16].

*What this buys / what this costs.* Short-code PAKE bootstraps mutual
authentication from nothing, using the humans' side channel instead of PKI.
An attacker with only a network position cannot mount an offline dictionary
attack (one online guess per attempt — hence 16 bits is tolerable there);
an attacker who *hears the code* wins outright. For LANdir the analogous
observation is favorable: nobody has to type the code, so a QR-embedded
secret can carry 128+ bits, and the QR's delivery (the host device's own
screen) is much harder to intercept en masse than a spoken code.

## 5. TLS-PSK: why it is unavailable here

RFC 4279 defines pre-shared-key TLS ciphersuites; its security considerations
are honest about costs: no PFS for the plain PSK suites (§7.1; DHE_PSK fixes
that), offline dictionary attacks against captured handshakes when the PSK is
low-entropy (§7.2), cleartext PSK identity (§7.3), and a recommendation that
administrators configuring PSKs have a random-PSK generator available
(§7.2) [17]. None of the W3C/WHATWG specifications read for this report
exposes any way to provision a TLS-PSK into a stock browser's TLS stack —
browsers expose certificate-based identity and nothing else — so TLS-PSK
only serves custom clients, where a Noise-style or PAKE-based protocol serves
equally well. (*Verification caveat:* the browser gap is an absence-of-feature
claim argued from the specs read, not a sentence in any one spec.)

*What this buys / what this costs.* One well-audited TLS stack doing both
auth and confidentiality — but only for configurable clients. Inapplicable
to LANdir's browser clients; unnecessary for the app.

## 6. The browser-side reality (the hardest constraint)

Matasano's canonical writeup names the problem: "Secure delivery of
Javascript to browsers is a chicken-egg problem. ... If you don't trust the
network to deliver a password, or, worse, don't trust the server not to keep
user secrets, you can't trust them to deliver security code. The same
attacker who was sniffing passwords or reading diaries before you introduce
crypto is simply hijacking crypto code after you do" [22]. The WebCrypto
spec agrees in its own security considerations: script injection "may come
from other applications, for which the judicious use of Content Security
Policy may mitigate, or it may come from hostile network intermediaries, for
which the use of Transport Layer Security may mitigate" (§6.2), and users
should know that applications using these APIs "will have full access to all
messages exchanged, regardless of the cryptography employed" (§6.3) [18].

Concretely for LANdir, in increasing severity:

1. **WebCrypto availability.** `SubtleCrypto` is annotated `[SecureContext]`
   in the spec IDL — `[Exposed=(Window,Worker)] interface Crypto {
   [SecureContext] readonly attribute SubtleCrypto subtle; ...}` (WebCrypto
   editor's draft [19]). Per the Secure Contexts algorithm, "Potentially
   Trustworthy" covers https/wss, loopback (127.0.0.0/8, ::1/128),
   `localhost`, and `file:`; everything else — including `http://` origins on
   LAN IPs — is not trustworthy (Secure Contexts §3.1) [20]. **So on
   `http://192.168.x.y:8000/...`, conforming browsers expose no
   `crypto.subtle` at all.** Any browser-side sealing for LANdir must embed
   pure-JS crypto in the static page (mechanically possible with a compact
   X25519+secretbox implementation; it will not be constant-time hardware).
   Safari's behavior on insecure origins was not verified.
2. **SRI is dead on arrival over HTTP.** "Integrity metadata delivered by a
   context that is not a Secure Context such as an HTTP page, only protects
   an origin against a compromise of the server where an external resource is
   hosted. Network attackers can alter the digest in-flight (or remove it
   entirely, or do absolutely anything else to the document), just as they
   could alter the response the hash is meant to validate" (SRI §5.1) [21].
   Note this is the spec killing its own mechanism over plain HTTP — not a
   blog opinion.
3. **URL-fragment keys stop only passive attackers.** The fragment component
   (RFC 3986 §3.5 [26]) is "not sent in requests" (RFC 9110 §17.11) [25], so key material in the fragment
   never crosses the wire — the reason Firefox Send put its 128-bit AES-GCM
   key "appended to the share url as a #fragment" [23]. But the fragment is
   fully readable by page JavaScript via `location` — the same JavaScript a
   first-use MITM replaces. A first-load code swap reads the fragment,
   exfiltrates the key, or seals the upload for the attacker. So the
   fragment trick survives *passive* observation and dies against an active
   first-use MITM — the exact attacker it is usually marketed against. Any
   such scheme without a delivered-code root of trust is TOFU-or-worse,
   named as such.
4. **ETag / cache pinning: not a mechanism.** No browser treats its HTTP
   cache as a trust root or provides an enforced "pin this exact script and
   refuse new versions" primitive; an attacker controlling the plain-HTTP
   response can inject `no-store` directives and rewrite everything. The SRI
   §5.1 reasoning applies verbatim: the digest and the bytes it authenticates
   travel over the same attacker-controlled channel [21]. **Conclusion: there
   is no way, within the current web platform, to authenticate first-load JS
   over plain HTTP.** The nearest escape is SQRL, which simply refuses
   page-delivered JS: authentication runs in a native app or pre-trusted
   browser extension (grc.com SQRL document set) [24] — which for LANdir is
   an argument for the Flutter app, not for the browser page.

*What this buys / what this costs.* WebCrypto or pure-JS crypto can encrypt
payloads before POST against the *passive* attacker class; it structurally
cannot defeat an active first-use MITM, because the trust channel would have
to be delivered by the untrusted channel. This is a theorem-shaped limitation,
not an implementation gap.

## 7. LANdir-specific assessment

### Where LANdir stands today

The browser session is fully cleartext: file names, bytes, and the 128-bit
token itself (it rides in the URL path of every request) are visible to
anyone who can observe the traffic or the QR. The token defends against
parties with *no* view of the traffic or the QR — a real property, since
other LAN devices cannot guess the URL — but it is neither confidentiality
nor authentication: a passive observer of a single request learns the token.
The QR code, however, is a genuine out-of-band channel operated by the host
device's own screen — the strongest asset LANdir has. Note the QR terminal
rendering (and container `--url` remapping) becomes security-relevant the
moment it carries key material.

### Candidate architectures

| | (a) PSK in QR + JS PAKE | (b) X25519 pubkey in fragment, JS ECDH-seal, TOFU fingerprint | (c) crypto in Flutter app only | (d) hybrid: app E2E + browser opportunistic |
|---|---|---|---|---|
| Passive LAN observer | stopped | stopped (fragment off-wire [25]; ephemeral ECDH) | stopped | stopped |
| Active first-use MITM, **browser** | **wins** — swaps page JS on first GET | **wins** — same; also reads the fragment | n/a (browser excluded from secure path) | browser loses (documented); app holds |
| Active first-use MITM, **app** | limited by QR entropy (PAKE guess game, wormhole-style [11]) | cannot impersonate server (pubkey came via QR, not the network): DoS only, WireGuard-style [6] | same as (b)'s app half | same as (b)'s app half |
| QR channel's payload | shared secret (per run) | server static pubkey | server static pubkey | one pubkey serving both paths |
| Downgrade ("pretend scheme absent") | browser: page JS decides (attacker-controlled); app: unaffected by definition | app: Noise §14 rollback caution — negotiate inside the transcript, not as a preamble [7] | — no coexisting modes to confuse | app must not trust any "plain mode" signal from the network |
| Key management | per-run random PSK; race: both from QR | host keypair persisted; ephemeral client keys; HKDF → per-file AEAD | host keypair in app storage; Signal-style rescan [13] | host keypair + QR distribution |
| SPEC interactions (static HTML, no reflection) | PAGE grows a JS PAKE; handshake values stay in POST JSON, page unchanged | PAGE grows JS ECDH; page unchanged otherwise | core stays pure-Dart; golden vectors extend cleanly | as (b); PAGE grows |
| Leftover risk | browser first-use MITM stays; PAKE adds complexity where QR already carries full entropy | browser first-use MITM stays; fragment in browser history/clipboard (accepted by Firefox Send [23]) | browser users get nothing; LANdir's browser-usability promise weakened; distribution trust = app signing (currently debug-signed APK per README) | (b)+(c) residuals, no new ones |
| Verdict | dominated by (b): same browser weakness, more protocol, QR entropy spent on a PAKE where a straight pubkey does the job | best single mechanism | strongest security; abandons the core "plain browser works" promise for sensitive content | **recommended** |

Concrete recommendation, option (d):

1. The Dart core generates an X25519 keypair at first run and persists it.
2. Extend the host's QR code (and printed URL) with the server's long-term
   public key, e.g. `http://ip:port/<token>/#<pubkey-base64url>`. Both the
   fragment stays off the wire [25] and capacity is fine: the pure-Dart QR
   encoder supports versions 1–6 at EC level M (ARCHITECTURE.md), and a
   version-6 byte-mode QR carries 106 bytes — ample for a ~92-byte URL.
3. **App client**: ECDH(client-ephemeral, host-static) → HKDF → per-file
   AES-GCM/secretbox sealing over the existing upload/download endpoints
   (encrypted bodies under new content types; listing can stay plaintext or
   be sealed once the session key exists). Because the host pubkey arrived
   via the QR and the app's crypto code arrived in the app binary, an active
   MITM's best effort is denial of service — the CurveCP/WireGuard result
   [6][8]. A Signal-style fingerprint rescan (host shows the key hash; the
   app rescans a displayed QR) closes the "photograph the QR" residual into
   a deliberate-act threat [13][14].
4. **Browser client** (optional, honestly labeled): pure-JS X25519+AEAD
   (no WebCrypto dependency — §6.1) in the static PAGE, reading the pubkey
   from the fragment and sealing upload/download bodies. This defeats the
   passive LAN observer — LANdir's dominant realistic adversary — and
   nothing else. The page should say exactly that.
5. **State**: keep the token per-run (it is a capability, not an identity).
   If TOFU pinning is added in the app, pin to (host, port, pubkey), never to
   the per-run token — otherwise every run re-enters the first-use window.
   The static-HTML/no-reflection rules are preserved: handshake values ride
   POST JSON bodies like `/files` already does; the PAGE never reflects
   request data.
6. **Modes**: do not make encryption a network-negotiated feature for the
   browser path. An attacker who controls the wire controls any "the server
   doesn't support crypto" fallback (the SRI §5.1 pattern, and Noise §14's
   rollback warning [7][21]); a page that talks plaintext on a plain-HTTP
   network was never going to be protected anyway.

### Threat-model ladder (what each rung buys)

- **Rung 1 — passive LAN observer** (other devices on the LAN, monitor-mode
  Wi-Fi; nobody saw the QR). Today they read everything including the token.
  Option (b)'s JS sealing defeats this rung even in the browser; the app path
  trivially too. This alone justifies the browser-side work.
- **Rung 2 — active MITM from first use** (ARP spoof, rogue AP, hostile LAN
  node). The browser client **cannot be defended** (§6 is structural);
  document it, make the app the secure path (QR-authenticated host key), and
  point users who need full protection at the reverse-proxy TLS deployment
  README already describes — with TLS the origin becomes a secure context,
  restoring WebCrypto [19][20] and making SRI meaningful again [21].
- **Rung 3 — insider** (anyone holding the QR, anyone who is the host).
  The QR *is* the capability; the host is by design a trusted endpoint that
  stores plaintext files. No option in scope raises this rung; raising it
  would mean end-to-end sealing between *clients*, a different product.

## Limitations / open questions

- Do not invent a protocol: reuse SPAKE2/Noise-derived constructions exactly
  as wormhole and WireGuard do; the subtleties (transcript-bound negotiation,
  subgroup checks, nonce discipline) are where the bodies are buried
  (RFC 9382 §7, Noise §14) [2][7].
- Browser TLS-PSK absence: argued from spec silence, not a positive spec
  statement (§5).
- Safari's exposure of `crypto.subtle` on insecure origins, and the current
  browser-shipping matrix for WebCrypto X25519, were **not** verified against
  a primary source; the recommendation deliberately avoids depending on
  WebCrypto for the browser path.
- Smartphone-camera QR scanning UX for a fragment-augmented URL (~92 bytes)
  is expected to work on v6 codes but has not been device-tested.
- If the container's `--url` remaps origins, the QR's key component must
  still describe the same keypair the process actually uses — an ADR-level
  detail not resolved here.

## Sources

Every URL below was fetched and read during this research; claims are cited
from these documents, not from secondary summaries.

1. https://www.rfc-editor.org/rfc/rfc2945.txt — RFC 2945, *The SRP
   Authentication and Key Exchange System* (T. Wu, 2000). Cited: abstract,
   §1, §2. [1]
2. https://www.rfc-editor.org/rfc/rfc9382.txt — RFC 9382, *SPAKE2, a
   Password-Authenticated Key Exchange* (W. Ladd, 2023). Cited: §7
   (augmentation/password-equivalent, group-membership MUSTs). [2]
3. https://www.rfc-editor.org/rfc/rfc9383.txt — RFC 9383, *SPAKE2+, an
   Augmented PAKE* (Taubert, Wood, 2023). Cited: §3.4, §6. [3]
4. https://www.rfc-editor.org/rfc/rfc9807.txt — RFC 9807, *The OPAQUE
   Augmented PAKE Protocol* (Bourdrez, Krawczyk, Lewi, Wood, July 2025).
   Cited: abstract. Number confirmed against the RFC index
   (https://www.rfc-editor.org/rfc-index.txt): RFC 9380 is *Hashing to
   Elliptic Curves*, not OPAQUE. [4]
5. https://www.rfc-editor.org/rfc/rfc4251.txt — RFC 4251, *SSH Protocol
   Architecture* (Ylonen, Lonvick, 2006). Cited: §4.1, §9.3.4. [5]
6. https://www.wireguard.com/papers/wireguard.pdf — A. Donenfeld, *WireGuard:
   Next Generation Kernel Network Tunnel* (NDSS). Cited: §1, §4, §5.2. [6]
7. https://noiseprotocol.org/noise.html — T. Perrin, *The Noise Protocol
   Framework* (rev. 2018-07-11). Cited: §7.5 (naming, XX pattern), §14
   (Authentication, Rollback, Static key reuse). [7]
8. http://curvecp.org/ — D. J. Bernstein, *CurveCP: Usable security for the
   Internet* (index; /security.html; /addressing.html). Cited: MITM answer,
   client prerequisites. [8]
9. https://cr.yp.to/highspeed/coolnacl-20120725.pdf — Bernstein, Lange,
   Schwabe, *The security impact of a new cryptographic library* (2012).
   Cited: abstract (NaCl design decisions). [9]
10. https://github.com/magic-wormhole/magic-wormhole-protocols/blob/main/client-protocol.md
    — magic-wormhole client protocol (primary doc). Cited: `pake` phase
    (SPAKE2 X+M*pw), `wormhole:verifier`, SecretBox/HKDF phases. [10]
11. https://github.com/magic-wormhole/magic-wormhole/blob/master/docs/attacks.rst
    — magic-wormhole attacks/threat-model doc. Cited: 16-bit codes,
    one-guess MITM, code-leak = 100% reliability. [11]
12. https://github.com/magic-wormhole/magic-wormhole/blob/master/docs/introduction.rst
    — magic-wormhole introduction (rendezvous → PAKE → encrypted records). [12]
13. https://support.signal.org/hc/en-us/articles/360007060632-What-is-a-safety-number-and-why-do-I-see-that-it-changed
    — Signal Support, *What is a safety number*. Cited: "This does not verify
    anyone's identity", MITM advisory, in-person QR verification. [13]
14. https://signal.org/blog/verified-safety-number-updates/ — Signal blog,
    *Safety number updates* (moxie0, 16 Jun 2017). Cited: verified marking,
    manual approval before sending on change. [14]
15. https://github.com/schollz/croc — schollz/croc README. Cited: "Provides
    end-to-end encryption (using PAKE)", code-phrase PAKE. [15]
16. https://github.com/schollz/pake — the PAKE library croc uses
    (readme: "PAKE2 protocol" from Boneh–Shoup p. 789, built for croc);
    dependency `github.com/schollz/pake/v3 v3.2.1` verified in croc's go.mod. [16]
17. https://www.rfc-editor.org/rfc/rfc4279.txt — RFC 4279, *Pre-Shared Key
    Ciphersuites for TLS* (Eronen, Tschofenig, 2005). Cited: §7, §7.1, §7.2,
    §7.3. [17]
18. https://www.w3.org/TR/WebCryptoAPI/ — W3C *Web Cryptography API*
    Recommendation. Cited: §6.2, §6.3. [18]
19. https://w3c.github.io/webcrypto/ — Web Cryptography API editor's draft.
    Cited: IDL `[SecureContext] readonly attribute SubtleCrypto subtle`. [19]
20. https://w3c.github.io/webappsec-secure-contexts/ — W3C *Secure Contexts*.
    Cited: §3.1 is-origin-potentially-trustworthy algorithm. [20]
21. https://www.w3.org/TR/SRI/ — W3C *Subresource Integrity*. Cited: §5.1
    "Non-secure contexts remain non-secure". [21]
22. https://web.archive.org/web/20110925120934/http://www.matasano.com/articles/javascript-cryptography/
    — *Javascript Cryptography Considered Harmful* (Matasano; original
    matasano.com URL is dead, this is the archived copy of the original
    publication). Cited: secure-delivery chicken-egg problem. [22]
23. https://github.com/mozilla/send/blob/master/docs/encryption.md — Firefox
    Send encryption doc (product discontinued 2021; repo archived). Cited:
    AES-GCM via Web Crypto, key appended to share URL as #fragment. [23]
24. https://www.grc.com/sqrl/sqrl.htm — S. Gibson, SQRL document set
    (Explained / Operating Details / Cryptography / On The Wire PDFs).
    Cited as evidence SQRL keeps authentication code out of page-delivered
    JS (native apps and browser extensions only). [24]
25. https://www.rfc-editor.org/rfc/rfc9110.txt — RFC 9110, *HTTP Semantics*.
    Cited: §17.11 ("fragment identifiers... are not sent in requests"). [25]
26. https://www.rfc-editor.org/rfc/rfc3986.txt — RFC 3986, *URI Generic
    Syntax*. Cited: §3.5 (fragment component). [26]

No purely secondary sources were used for any spec-owned or code-owned claim.
The Matasano article is treated as the primary source for its own argument,
per its original publication; an LWN summary of Warner's PyCon talk was
found but deliberately not cited — all wormhole claims come from the
project's own protocol and threat-model documents.
