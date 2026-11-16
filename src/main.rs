//! Landir - a simple LAN file upload server (Rust implementation).
//!
//! Usage:
//!     landir [--port PORT] [--dir UPLOADS_DIR] [--insecure]
//!
//! Defaults: port 8000, uploads in ./uploads, secret mode ON. Prints the URL
//! to open from any device on the same network, rendered as a scannable QR
//! code. By default the pages live under a random unguessable URL path;
//! everything else 404s. Pass --insecure (-i) for plain /, /upload, ... URLs.
//! If the requested port is occupied, a random high port (32768-60999) is used.

mod activity;
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
    /// Port to listen on (falls back to a random high port if occupied)
    #[arg(long, default_value_t = 8000)]
    port: i64,
    /// Directory where uploaded files are stored
    #[arg(long, default_value = "uploads")]
    dir: PathBuf,
    /// Serve on plain /, /upload, ... URLs with no token (default is secret
    /// mode with a random URL path, included in the QR code)
    #[arg(long, short = 'i')]
    insecure: bool,
}

fn urandom(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buf))
        .expect("failed to read /dev/urandom");
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

async fn bind_available(requested: Option<u16>) -> tokio::net::TcpListener {
    if let Some(p) = requested {
        if let Ok(l) = tokio::net::TcpListener::bind(("0.0.0.0", p)).await {
            return l;
        }
    }
    // Port is occupied; try random high ports (IANA dynamic/private range)
    for _ in 0..100 {
        let r = urandom(2);
        let port = 32768 + u16::from_be_bytes([r[0], r[1]]) % (60999 - 32768 + 1);
        if let Ok(l) = tokio::net::TcpListener::bind(("0.0.0.0", port)).await {
            return l;
        }
    }
    eprintln!("Could not find an available port after 100 attempts");
    exit(1)
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

    // out-of-range --port behaves like an occupied port: fall back to random
    let requested = if (0..=65535).contains(&cli.port) {
        Some(cli.port as u16)
    } else {
        None
    };
    let listener = bind_available(requested).await;
    let port = listener.local_addr().expect("local addr").port();

    // 16 random bytes -> 22-char URL-safe token (~128 bits of entropy)
    let token = if cli.insecure {
        None
    } else {
        Some(base64url(&urandom(16)))
    };
    let paths = paths::Paths::new(token.as_deref());

    let url = format!("http://{}:{}{}", lan_ip(), port, paths.page);

    let state = Arc::new(server::AppState {
        upload_dir: upload_dir.clone(),
        upload_real,
        token,
        paths,
        activity: activity::ActivityLog::new(),
    });
    let app = server::router(state.clone());
    // ConnectInfo lets the activity tracker see client IPs.
    let make_svc = app.into_make_service_with_connect_info::<SocketAddr>();

    if tui::is_tty() {
        // Interactive terminal (e.g. `podman run -it`): full-screen UI on the
        // main thread, HTTP server on a tokio task.
        let server = tokio::spawn(async move {
            axum::serve(listener, make_svc)
                .with_graceful_shutdown(async {
                    let _ = tokio::signal::ctrl_c().await;
                })
                .await
                .expect("server error");
        });
        let _ = tui::run(&state.activity, &url);
        server.abort();
        println!("Stopped.");
        return;
    }

    // No TTY (container logs, pipes): plain filtered log lines.
    println!("Uploads directory: {}", upload_dir.display());
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
