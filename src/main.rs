//! LANdir - a simple LAN file upload server (Rust implementation).
//!
//! Usage:
//!     landir [--port PORT] [--dir UPLOADS_DIR] [--insecure | --encrypt]
//!           [--max-upload BYTES]
//!
//! Defaults: port 8000, uploads in ./uploads, secret mode ON. Prints the URL
//! to open from any device on the same network, rendered as a scannable QR
//! code. By default the pages live under a random unguessable URL path;
//! everything else 404s. Pass --insecure (-i) for plain /, /upload, ... URLs.
//! Pass --encrypt for encrypted mode: no token, a long-term X25519 host key
//! in the QR fragment (#k=...), and only the sealed endpoints (/supload,
//! /sfiles, /sls, /sfl) answering — a LANdir app client is required to access
//! it, since browsers cannot use encryption over plain HTTP (every plain
//! route 404s).
//! Pass --max-upload BYTES to reject uploads larger than BYTES with 413
//! before their body is read (default: no limit — the request body is
//! buffered in memory, so a cap bounds the memory an upload can cost).
//! If the requested port is occupied — or --port 0 is given, which delegates
//! the choice — a random high port (32768-60999) is used.
//!
//! In a container the port clients reach is the *mapped* port, which the
//! process cannot discover. Pass --url to set the advertised origin:
//!     landir --url http://192.168.1.50:18080
//! With --url set an occupied port is a fatal error, since the printed URL
//! could not be made to match the mapping.

mod activity;
mod crypto;
mod listing;
mod page;
mod paths;
mod qr;
mod security;
mod server;
mod tui;

use std::io::Read;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::exit;
use std::sync::Arc;

use clap::Parser;

#[derive(Parser)]
#[command(about = "LAN file upload server", version)]
struct Cli {
    /// Port to listen on (0, or an occupied port, falls back to a random
    /// high port, unless --url is set, in which case an occupied port is
    /// an error)
    #[arg(long, default_value_t = 8000)]
    port: i64,
    /// Directory where uploaded files are stored
    #[arg(long, default_value = "uploads")]
    dir: PathBuf,
    /// Serve on plain /, /upload, ... URLs with no token (default is secret
    /// mode with a random URL path, included in the QR code)
    #[arg(long, short = 'i', conflicts_with = "encrypt")]
    insecure: bool,
    /// Encrypted mode: no token, host key in the QR fragment (#k=...), only
    /// the sealed endpoints (/supload, /sfiles, /sls, /sfl) answer — requires
    /// a LANdir app client; browsers cannot use encryption over plain HTTP
    #[arg(long, conflicts_with = "insecure")]
    encrypt: bool,
    /// Reject uploads larger than BYTES with 413, before the body is read
    /// (default: no limit). In encrypted mode the limit applies to the
    /// sealed upload payload
    #[arg(long, value_name = "BYTES", default_value_t = 0)]
    max_upload: u64,
    /// Origin to advertise in the printed URL and QR code, e.g.
    /// http://192.168.1.50:18080 (for a container port mapping). The token
    /// path is still appended. Defaults to http://<lan-ip>:<bound-port>
    #[arg(long, value_name = "ORIGIN")]
    url: Option<String>,
}

/// The origin (scheme + host + port) advertised to clients, without the page
/// path. `--url` wins; otherwise the host's LAN IP and the bound port are
/// used, which is only correct when nothing (e.g. a port mapping) sits
/// between the process and the client.
fn advertised_origin(override_url: Option<&str>, port: u16) -> Result<String, String> {
    match override_url {
        Some(raw) => parse_origin(raw),
        None => Ok(format!("http://{}:{}", lan_ip(), port)),
    }
}

/// Validate a user-supplied origin: `http`/`https` scheme, a non-empty host,
/// a numeric port in 1-65535 when present, no path, query or fragment. A
/// malformed value must fail at startup rather than produce a QR code that
/// scans to nonsense.
fn parse_origin(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim().trim_end_matches('/');
    let (scheme, rest) = trimmed
        .split_once("://")
        .ok_or_else(|| format!("--url must include a scheme (http:// or https://): {raw}"))?;
    let scheme = scheme.to_ascii_lowercase();
    if scheme != "http" && scheme != "https" {
        return Err(format!("--url scheme must be http or https: {raw}"));
    }
    if rest.is_empty() || rest.contains('/') || rest.contains('?') || rest.contains('#') {
        return Err(format!(
            "--url must be an origin only (scheme://host[:port], no path): {raw}"
        ));
    }
    // Reject control characters (C0, DEL, C1). The value is echoed to the
    // terminal in plain-log mode and in error messages, where an ESC byte
    // would be interpreted as a terminal escape (e.g. OSC-52 clipboard
    // writes). Whitespace is a subset of this.
    if rest
        .chars()
        .any(|c| c.is_control() || ('\u{80}'..='\u{9f}').contains(&c) || c.is_whitespace())
    {
        return Err(format!("--url host must not contain whitespace or control characters: {raw}"));
    }
    // Split a numeric port off the last colon. Anything else containing a
    // colon must be a bracketed IPv6 literal ([::1]), which URLs require.
    let host = if let Some((h, p)) = rest.rsplit_once(':') {
        if !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()) {
            // Parsed as u64 so an absurdly long digit run overflows into an
            // error instead of a panic; u16 range is checked after.
            let port: u64 = p
                .parse()
                .map_err(|_| format!("--url port must be within 1-65535: {raw}"))?;
            if !(1..=65535).contains(&port) {
                return Err(format!("--url port must be within 1-65535: {raw}"));
            }
            h
        } else if rest.starts_with('[') && rest.ends_with(']') {
            rest // bracketed IPv6 without a port
        } else {
            return Err(format!(
                "--url port must be numeric; IPv6 addresses must be bracketed: {raw}"
            ));
        }
    } else {
        rest
    };
    if host.is_empty() {
        return Err(format!("--url host must not be empty: {raw}"));
    }
    if host.contains(':') && !(host.starts_with('[') && host.ends_with(']')) {
        return Err(format!("--url IPv6 addresses must be bracketed: {raw}"));
    }
    Ok(format!("{scheme}://{rest}"))
}

pub(crate) fn urandom_into(buf: &mut [u8]) {
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(buf))
        .expect("failed to read /dev/urandom");
}

fn urandom(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    urandom_into(&mut buf);
    buf
}

/// URL-safe base64 without padding (like Python's token_urlsafe).
fn base64url(data: &[u8]) -> String {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut s = String::new();
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        s.push(A[(n >> 18 & 63) as usize] as char);
        s.push(A[(n >> 12 & 63) as usize] as char);
        if chunk.len() > 1 {
            s.push(A[(n >> 6 & 63) as usize] as char);
        }
        if chunk.len() > 2 {
            s.push(A[(n & 63) as usize] as char);
        }
    }
    s
}

/// What to do when the requested port is busy.
#[derive(Clone, Copy, PartialEq, Eq)]
enum OnBusy {
    /// Move to a random high port. The printed URL follows the actual port,
    /// so it still works.
    Fallback,
    /// Fail: an advertised URL (--url) pins the mapping, so a fallback would
    /// print a URL no client could reach.
    Fail,
}

/// Bind the requested port and return the listener, or a ready-to-print
/// error message (only [OnBusy::Fail] errors on a busy port).
async fn bind_available(
    requested: Option<u16>,
    on_busy: OnBusy,
) -> Result<tokio::net::TcpListener, String> {
    if let Some(p) = requested {
        match tokio::net::TcpListener::bind(("0.0.0.0", p)).await {
            Ok(l) => return Ok(l),
            Err(e) if on_busy == OnBusy::Fail => {
                return Err(format!(
                    "cannot listen on port {p}: {e}\n\
                     --url advertises a fixed address, so falling back to another \
                     port would print a URL that does not work.\n\
                     Free port {p}, or map a different host port and update --url."
                ));
            }
            Err(_) => {}
        }
    }
    // Port is occupied; try random high ports (IANA dynamic/private range)
    for _ in 0..100 {
        let r = urandom(2);
        let port = 32768 + u16::from_be_bytes([r[0], r[1]]) % (60999 - 32768 + 1);
        if let Ok(l) = tokio::net::TcpListener::bind(("0.0.0.0", port)).await {
            return Ok(l);
        }
    }
    Err("could not find an available port after 100 attempts".to_string())
}

/// The URL printed at startup and encoded in the QR code. In encrypted mode
/// the host key rides in the fragment: `http://ip:port/#k=<base64url(pubkey)>`
/// (padding stripped). The fragment never crosses the wire; generic
/// camera-scan browsers ignore it, the LANdir app pins it.
fn advertised_url(origin: &str, page: &str, host_key: Option<&crypto::HostKey>) -> String {
    let base = format!("{origin}{page}");
    match host_key {
        Some(hk) => format!("{base}#k={}", base64url(hk.public.as_bytes())),
        None => base,
    }
}

fn lan_ip() -> String {
    match std::net::UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => match s.connect("8.8.8.8:80").and_then(|_| s.local_addr()) {
            Ok(a) => a.ip().to_string(),
            Err(_) => "127.0.0.1".to_string(),
        },
        Err(_) => "127.0.0.1".to_string(),
    }
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let upload_dir = if cli.dir.is_absolute() {
        cli.dir.clone()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(&cli.dir)
    };
    tokio::fs::create_dir_all(&upload_dir)
        .await
        .expect("failed to create uploads directory");
    let upload_real = std::fs::canonicalize(&upload_dir).expect("failed to canonicalize uploads dir");

    // 0 delegates the choice (like an out-of-range --port): go straight
    // to the random high-port loop, not to OS-ephemeral binding.
    let requested = if (1..=65535).contains(&cli.port) {
        Some(cli.port as u16)
    } else {
        None
    };
    let on_busy = if cli.url.is_some() { OnBusy::Fail } else { OnBusy::Fallback };
    let listener = match bind_available(requested, on_busy).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("error: {e}");
            exit(1)
        }
    };
    let port = listener.local_addr().expect("local addr").port();

    // 16 random bytes -> 22-char URL-safe token (~128 bits of entropy).
    // Encrypted mode is key-only: no token is generated (the host key ships
    // in the same QR and is strictly stronger), so every plaintext route 404s.
    let token = if cli.insecure || cli.encrypt {
        None
    } else {
        Some(base64url(&urandom(16)))
    };
    let paths = paths::Paths::new(token.as_deref());

    // Encrypted mode: load (or create and persist) the long-term host key.
    let host_key = if cli.encrypt {
        match crypto::load_or_create_host_key(&upload_dir) {
            Ok(k) => Some(k),
            Err(e) => {
                eprintln!("error: cannot load/create the host key: {e}");
                exit(1);
            }
        }
    } else {
        None
    };

    let origin = match advertised_origin(cli.url.as_deref(), port) {
        Ok(o) => o,
        Err(e) => {
            // exit 2 = usage error (clap's own code for bad arguments);
            // exit 1 above = runtime error.
            eprintln!("error: {e}");
            exit(2)
        }
    };
    let mut url = advertised_url(&origin, &paths.page, host_key.as_ref());
    if cli.encrypt && url.len() > 106 {
        // Never truncate key material to fit the QR (versions 1-6 hold 106
        // bytes): warn and fall back to the keyless URL — the app host's
        // behavior. The app cannot pair from this QR; the printed URL still
        // scans to an honest address.
        eprintln!(
            "warning: URL + host key exceeds the QR capacity (106 bytes); \
             advertising the keyless URL instead — the app cannot pair from this QR"
        );
        url = format!("{origin}{}", paths.page);
    }

    let state = Arc::new(server::AppState {
        upload_dir: upload_dir.clone(),
        upload_real,
        token,
        paths,
        activity: activity::ActivityLog::new(),
        encrypted: cli.encrypt,
        host_key,
        max_upload_bytes: cli.max_upload,
    });
    let app = server::router(state.clone());
    // ConnectInfo lets the activity tracker see client IPs.
    let make_svc = app.into_make_service_with_connect_info::<SocketAddr>();

    if tui::is_tty() {
        // Interactive terminal (e.g. `podman run -it`): full-screen UI on the
        // main thread, HTTP server on a tokio task. While the UI owns the
        // terminal, events must not be printed as plain log lines.
        activity::set_plain_mode(false);
        let shutdown = Arc::new(tokio::sync::Notify::new());
        let server_shutdown = Arc::clone(&shutdown);
        let server = tokio::spawn(async move {
            axum::serve(listener, make_svc)
                .with_graceful_shutdown(async move {
                    server_shutdown.notified().await;
                })
                .await
                .expect("server error");
        });
        let _ = tui::run(&state.activity, &url, cli.encrypt);
        activity::set_plain_mode(true);
        // Quit must not truncate in-flight uploads (an aborted write would
        // leave a stale .landir_tmp_* behind): signal graceful shutdown and
        // let the server drain before exiting. The bound keeps a wedged
        // connection from hanging shutdown forever.
        shutdown.notify_one();
        let _ = tokio::time::timeout(std::time::Duration::from_secs(10), server).await;
        println!("Stopped.");
        return;
    }

    // No TTY (container logs, pipes): plain filtered log lines.
    println!("Uploads directory: {}", upload_dir.display());
    if cli.encrypt {
        // Tell the host user how to reach an encrypted host: only a LANdir
        // app client can — encryption is not possible in a browser over
        // plain HTTP, so every plain-HTTP route answers 404.
        println!("Encryption mode ON: a LANdir client (app) is required to access this host —");
        println!("scan the QR code with the LANdir app. Browsers cannot use encryption over");
        println!("plain HTTP; all plain-HTTP routes answer 404.");
    }
    println!("Open {url}  (Ctrl+C to stop)");
    match qr::qr_terminal(&url) {
        Ok(q) => println!("{q}"),
        Err(e) => println!("(no QR code: {e})"),
    }
    // As PID 1 in a container the kernel only delivers signals that have a
    // handler installed; without this, Ctrl+C/SIGINT would be dropped.
    axum::serve(listener, make_svc)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
        .expect("server error");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn override_origin_replaces_host_and_port() {
        assert_eq!(
            advertised_origin(Some("http://192.168.1.50:18080"), 8000).unwrap(),
            "http://192.168.1.50:18080"
        );
    }

    #[test]
    fn override_origin_keeps_https_and_trims_trailing_slash() {
        assert_eq!(
            advertised_origin(Some("https://landir.example.com/"), 8000).unwrap(),
            "https://landir.example.com"
        );
    }

    #[test]
    fn override_origin_without_port_is_allowed() {
        // https behind a reverse proxy on the default port
        assert_eq!(
            advertised_origin(Some("https://files.example.com"), 8000).unwrap(),
            "https://files.example.com"
        );
    }

    #[test]
    fn override_origin_is_case_insensitive_for_the_scheme() {
        assert_eq!(
            advertised_origin(Some("HTTP://10.0.0.5:9000"), 8000).unwrap(),
            "http://10.0.0.5:9000"
        );
    }

    #[test]
    fn override_origin_rejects_a_missing_scheme() {
        let err = advertised_origin(Some("192.168.1.50:18080"), 8000).unwrap_err();
        assert!(err.contains("scheme"), "{err}");
    }

    #[test]
    fn override_origin_rejects_a_non_http_scheme() {
        let err = advertised_origin(Some("ftp://192.168.1.50:18080"), 8000).unwrap_err();
        assert!(err.contains("http"), "{err}");
    }

    #[test]
    fn override_origin_rejects_a_path() {
        // A path prefix would need routing changes; accepting and ignoring it
        // would be worse than refusing it.
        let err = advertised_origin(Some("http://192.168.1.50:18080/landir"), 8000)
            .unwrap_err();
        assert!(err.contains("origin only"), "{err}");
    }

    #[test]
    fn override_origin_rejects_an_empty_host() {
        // `http://` fails on the missing remainder; `http://:8000` is the
        // case that actually exercises the empty-host check.
        assert!(advertised_origin(Some("http://"), 8000).is_err());
        let err = advertised_origin(Some("http://:8000"), 8000).unwrap_err();
        assert!(err.contains("host must not be empty"), "{err}");
    }

    #[test]
    fn override_origin_rejects_a_non_numeric_port() {
        let err = advertised_origin(Some("http://host:abc"), 8000).unwrap_err();
        assert!(err.contains("port must be numeric"), "{err}");
    }

    #[test]
    fn override_origin_rejects_an_out_of_range_port() {
        for bad in ["http://host:99999", "http://host:0"] {
            let err = advertised_origin(Some(bad), 8000).unwrap_err();
            assert!(err.contains("1-65535"), "{bad}: {err}");
        }
    }

    #[test]
    fn override_origin_rejects_whitespace_in_the_host() {
        let err = advertised_origin(Some("http://a b"), 8000).unwrap_err();
        assert!(err.contains("whitespace"), "{err}");
    }

    #[test]
    fn override_origin_rejects_terminal_escape_sequences() {
        // The origin is echoed to the terminal in plain-log mode and error
        // messages; an ESC byte there would be interpreted as a terminal
        // escape (e.g. OSC-52 clipboard writes).
        let cases = [
            "http://a\u{1b}]52;c;bmFsd2F5\u{7}b", // OSC-52 clipboard write
            "http://a\u{1b}[2Jb",                 // CSI clear-screen
            "http://a\u{7}b",                     // BEL
            "http://a\u{9b}b",                    // C1 CSI (U+009B)
            "http://a\u{7f}b",                    // DEL
            "http://a\u{b}b",                     // vertical tab
        ];
        for bad in cases {
            let err = advertised_origin(Some(bad), 8000).unwrap_err();
            assert!(err.contains("control characters"), "{bad:?}: {err}");
        }
    }

    #[test]
    fn override_origin_rejects_an_absurdly_long_digit_port_without_panic() {
        // Regression: 40 digits pass the is_ascii_digit check but overflow
        // u32, which used to panic in parse().expect().
        let huge = format!("http://host:{}", "9".repeat(40));
        let err = advertised_origin(Some(&huge), 8000).unwrap_err();
        assert!(err.contains("1-65535"), "{err}");
    }

    #[test]
    fn override_origin_accepts_bracketed_ipv6() {
        assert_eq!(
            advertised_origin(Some("http://[::1]:18080"), 8000).unwrap(),
            "http://[::1]:18080"
        );
        assert_eq!(
            advertised_origin(Some("http://[::1]"), 8000).unwrap(),
            "http://[::1]"
        );
    }

    #[test]
    fn override_origin_rejects_an_unbracketed_ipv6() {
        let err = advertised_origin(Some("http://::1:8000"), 8000).unwrap_err();
        assert!(err.contains("bracketed"), "{err}");
    }

    #[test]
    fn without_override_the_bound_port_is_used() {
        let origin = advertised_origin(None, 8000).unwrap();
        assert!(origin.ends_with(":8000"), "{origin}");
        assert!(origin.starts_with("http://"), "{origin}");
    }

    #[tokio::test]
    async fn busy_port_fails_when_an_advertised_url_is_set() {
        // Occupy a port, then require it: the error must name the port.
        let held = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = held.local_addr().unwrap().port();
        let err = bind_available(Some(port), OnBusy::Fail).await.unwrap_err();
        assert!(err.contains(&format!("cannot listen on port {port}")), "{err}");
    }

    #[tokio::test]
    async fn busy_port_falls_back_without_an_advertised_url() {
        let held = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = held.local_addr().unwrap().port();
        let listener = bind_available(Some(port), OnBusy::Fallback)
            .await
            .expect("fallback must find another port");
        assert_ne!(listener.local_addr().unwrap().port(), port);
    }

    #[tokio::test]
    async fn port_zero_picks_a_random_high_port() {
        // 0 delegates the choice (no explicit request, like the out-of-range
        // --port): every draw must stay in the documented dynamic range
        // 32768-60999, not an OS-ephemeral port.
        for _ in 0..20 {
            let listener = bind_available(None, OnBusy::Fallback)
                .await
                .expect("must find a port");
            let port = listener.local_addr().unwrap().port();
            assert!((32768..=60999).contains(&port), "port {port} out of range");
        }
    }

    #[test]
    fn advertised_url_appends_the_secret_path() {
        // The token path must survive the override, or the QR would 404.
        let origin = advertised_origin(Some("http://192.168.1.50:18080"), 8000).unwrap();
        assert_eq!(
            format!("{origin}/abc123/"),
            "http://192.168.1.50:18080/abc123/"
        );
    }

    #[test]
    fn advertised_url_carries_host_key_fragment_when_encrypted() {
        let host = crypto::host_key_from_seed([3u8; 32]);
        let url = advertised_url("http://192.168.1.4:8000", "/", Some(&host));
        let expected_k = base64url(host.public.as_bytes());
        assert_eq!(url, format!("http://192.168.1.4:8000/#k={expected_k}"));
        // keyless hosts get the plain URL, no fragment
        assert_eq!(
            advertised_url("http://192.168.1.4:8000", "/tok/", None),
            "http://192.168.1.4:8000/tok/"
        );
        // a normal LAN URL + key fits the QR version cap (106 bytes)
        assert!(url.len() <= 106, "url={url}");
    }
}


