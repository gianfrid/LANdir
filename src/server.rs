//! HTTP layer. `router` is the seam: every endpoint is reachable through it,
//! so tests exercise the whole surface with `tower::oneshot` without sockets.

use std::convert::Infallible;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::{ConnectInfo, DefaultBodyLimit, FromRequest, FromRequestParts, Multipart, Request, State};
use axum::http::header::{CONTENT_DISPOSITION, CONTENT_LENGTH, CONTENT_TYPE};
use axum::http::request::Parts;
use axum::http::{StatusCode, Uri};
use axum::middleware::{self, Next};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;
use tokio_util::io::ReaderStream;

use crate::activity::{emit_event, ActivityLog};
use crate::crypto;
use crate::listing;
use crate::page::PAGE;
use crate::paths::Paths;
use crate::security;

pub struct AppState {
    pub upload_dir: PathBuf,
    pub upload_real: PathBuf,
    pub token: Option<String>,
    pub paths: Paths,
    pub activity: ActivityLog,
    /// Encrypted mode (--encrypt): only the sealed endpoints answer; every
    /// plaintext route (page included) is a blind 404, so files are not
    /// readable or writable without the host key.
    pub encrypted: bool,
    pub host_key: Option<crypto::HostKey>,
    /// Upload size cap from --max-upload; 0 = no limit (app parity: the
    /// Flutter host's maxUploadBytes). The cap exists for the OOM vector —
    /// the request body is buffered in memory before parsing, so an
    /// oversized upload can kill the process for every user, not just the
    /// sender.
    pub max_upload_bytes: u64,
}

/// Client IP from the connection; 0.0.0.0 when there is no ConnectInfo
/// (in-process tests drive the router without sockets).
pub struct ClientIp(pub IpAddr);

impl<S: Send + Sync> FromRequestParts<S> for ClientIp {
    type Rejection = Infallible;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Infallible> {
        Ok(parts
            .extensions
            .get::<ConnectInfo<SocketAddr>>()
            .map(|c| ClientIp(c.0.ip()))
            .unwrap_or(ClientIp(IpAddr::V4(Ipv4Addr::UNSPECIFIED))))
    }
}

/// Every request refreshes the client's presence; failed requests are logged
/// with the client IP (4xx/5xx, mirroring landir.py's send_error events —
/// redirects stay quiet). Listing polls and page loads are silent.
async fn track_activity(
    State(s): State<Arc<AppState>>,
    req: Request,
    next: Next,
) -> Response {
    let (mut parts, body) = req.into_parts();
    let ip = ClientIp::from_request_parts(&mut parts, &()).await.unwrap().0;
    let req = Request::from_parts(parts, body);
    s.activity.touch(ip);
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let resp = next.run(req).await;
    let status = resp.status();
    if status.is_client_error() || status.is_server_error() {
        emit_event(
            &s.activity,
            format!("{ip} {method} {path} -> {}", status.as_u16()),
        );
    }
    resp
}

pub fn router(state: Arc<AppState>) -> Router {
    // All routes must be registered before the activity layer: axum's
    // `layer` only wraps routes (and the fallback) added before it, so
    // anything after it would silently escape presence tracking.
    let app = if state.encrypted {
        // Encrypted mode: ONLY the sealed endpoints answer. Every plaintext
        // route (page, files, ls, fl, upload) falls through to the 404
        // fallback, so files are not readable or writable without the key.
        Router::new()
            .route(&state.paths.supload, post(sealed_upload).layer(DefaultBodyLimit::disable()))
            .route(&state.paths.sfiles, post(sealed_list_root))
            .route(&state.paths.sls, post(sealed_list_subdir))
            .route(&state.paths.sfl, post(sealed_download).layer(DefaultBodyLimit::disable()))
    } else {
        let mut app = Router::new()
            .route(&state.paths.page, get(serve_page))
            .route(&state.paths.files, get(list_root))
            .route(&format!("{}{{*rest}}", state.paths.ls_prefix), get(list_subdir))
            .route(&format!("{}{{*rest}}", state.paths.fl_prefix), get(download))
            // No upload size limit (known accepted limitation, see SPEC.md)
            .route(&state.paths.upload, post(upload).layer(DefaultBodyLimit::disable()));
        if let Some(token) = &state.token {
            // bare /<token> redirects (302, like the Python server) to the
            // trailing-slash page so relative URLs resolve
            let page = state.paths.page.clone();
            app = app.route(&Paths::bare_token(token), get(move || async move {
                Response::builder()
                    .status(StatusCode::FOUND)
                    .header(axum::http::header::LOCATION, &page)
                    .body(Body::empty())
                    .unwrap()
            }));
        } else {
            app = app.route("/index.html", get(serve_page));
        }
        app
    };
    // An explicit fallback (unlike axum's default 404) goes through the
    // activity layer, so unmatched paths — scanner probes, wrong URLs —
    // refresh presence and are logged like any other request, matching
    // the Python server which touches and logs every request.
    app.fallback(|| async { (StatusCode::NOT_FOUND, "not found") })
        .layer(middleware::from_fn_with_state(state.clone(), track_activity))
        .with_state(state)
}

async fn serve_page() -> Html<&'static str> {
    Html(PAGE)
}

fn json_response(body: String) -> Response<Body> {
    ([(CONTENT_TYPE, "application/json")], body).into_response()
}

/// Listing JSON for one directory (blocking fs work off the runtime).
async fn listing_json_for(dir: PathBuf, real: PathBuf) -> String {
    // read_dir + per-entry canonicalize are blocking: every client polls
    // this every few seconds, so it must not stall the runtime workers.
    tokio::task::spawn_blocking(move || listing::entries_json(&listing::list_dir(&dir, &real)))
        .await
        .unwrap_or_default()
}

async fn list_root(State(s): State<Arc<AppState>>) -> Response<Body> {
    json_response(listing_json_for(s.upload_dir.clone(), s.upload_real.clone()).await)
}

async fn list_subdir(State(s): State<Arc<AppState>>, uri: Uri) -> Response<Body> {
    let raw = uri.path();
    let rel = raw.strip_prefix(&s.paths.ls_prefix).unwrap_or(raw);
    let rel = percent_encoding::percent_decode_str(rel).decode_utf8_lossy().into_owned();
    let dir = s.upload_dir.clone();
    let real = s.upload_real.clone();
    // blocking fs work (component checks, is_dir, listing) off the runtime
    let listed = tokio::task::spawn_blocking(move || -> Option<Vec<listing::Entry>> {
        let mut dir = dir;
        for part in rel.split('/') {
            match security::safe_path_component(part) {
                Some(p) => dir.push(p),
                None => return None,
            }
        }
        if !security::inside_uploads(&dir, &real) || !dir.is_dir() {
            return None;
        }
        Some(listing::list_dir(&dir, &real))
    })
    .await
    .ok()
    .flatten();
    match listed {
        Some(entries) => json_response(listing::entries_json(&entries)),
        None => (StatusCode::NOT_FOUND, "not found").into_response(),
    }
}

async fn download(
    State(s): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    uri: Uri,
) -> Response<Body> {
    let raw = uri.path();
    let rel = raw.strip_prefix(&s.paths.fl_prefix).unwrap_or(raw).to_string();
    let dir = s.upload_dir.clone();
    let real = s.upload_real.clone();
    // download_lookup decodes internally; the raw path is passed as-is
    let path = tokio::task::spawn_blocking(move || security::download_lookup(&rel, &dir, &real))
        .await
        .ok()
        .flatten();
    let Some(path) = path else {
        return (StatusCode::NOT_FOUND, "not found").into_response();
    };
    let Ok(file) = tokio::fs::File::open(&path).await else {
        return (StatusCode::NOT_FOUND, "not found").into_response();
    };
    let len = file.metadata().await.map(|m| m.len()).unwrap_or(0);
    let fname = path
        .file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_default();
    emit_event(&s.activity, format!("{ip} downloaded {fname} ({len} B)"));
    Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "application/octet-stream")
        .header(CONTENT_DISPOSITION, format!("attachment; filename=\"{fname}\""))
        .header(CONTENT_LENGTH, len)
        .body(Body::from_stream(ReaderStream::new(file)))
        .unwrap()
}

async fn upload(State(s): State<Arc<AppState>>, req: Request) -> Response<Body> {
    let (mut parts, body) = req.into_parts();
    let ip = ClientIp::from_request_parts(&mut parts, &()).await.unwrap().0;
    // Pre-read rejection: the multipart parser otherwise buffers the whole
    // request body in memory, so an oversized upload must be rejected on the
    // Content-Length header alone — it costs one header line, not its full
    // size in RAM.
    if s.max_upload_bytes > 0 {
        let over = parts
            .headers
            .get(CONTENT_LENGTH)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<u64>().ok())
            .is_some_and(|cl| cl > s.max_upload_bytes);
        if over {
            return (StatusCode::PAYLOAD_TOO_LARGE, "Payload too large").into_response();
        }
    }
    // The route registered DefaultBodyLimit::disable, which is already in
    // the request parts (no upload size limit beyond the optional one, see
    // SPEC.md), so Multipart can stream the body as before.
    let req = Request::from_parts(parts, body);
    match Multipart::from_request(req, &s).await {
        Ok(multipart) => save_multipart(s, ip, multipart).await,
        Err(_) => (StatusCode::BAD_REQUEST, "Bad request").into_response(),
    }
}

/// Parse a multipart upload and save every file part through
/// `security::save_unique(security::safe_name(...))` — SPEC.md rule 1 applies
/// below the crypto layer exactly as for plaintext uploads.
async fn save_multipart(
    s: Arc<AppState>,
    ip: IpAddr,
    mut multipart: Multipart,
) -> Response<Body> {
    let mut saved = 0;
    let mut failed = false;
    while let Ok(Some(field)) = multipart.next_field().await {
        let Some(fname) = field.file_name().map(|f| f.to_string()) else {
            continue;
        };
        let Ok(data) = field.bytes().await else {
            continue;
        };
        let len = data.len();
        let dir = s.upload_dir.clone();
        let real = s.upload_real.clone();
        let raw_name = fname.clone();
        // Staged + atomically published: never overwrites, never visible
        // half-written (mirrors landir.py's save_unique). All the blocking
        // fs work runs off the runtime thread.
        let outcome = tokio::task::spawn_blocking(move || -> std::io::Result<Option<String>> {
            let Some(name) = security::safe_name(&fname, &real) else {
                return Ok(None); // rejected name: skip the part
            };
            security::save_unique(&name, &data, &dir)
        })
        .await;
        match outcome {
            Ok(Ok(Some(final_name))) => {
                emit_event(
                    &s.activity,
                    format!("{ip} uploaded {final_name} ({len} B)"),
                );
                saved += 1;
            }
            Ok(Ok(None)) => {} // rejected or no free name: skip the part
            Ok(Err(e)) => {
                // server-side save failure (disk full, dir gone, …):
                // surface it instead of misreporting a client error
                emit_event(
                    &s.activity,
                    format!("{ip} save failed for {raw_name:?}: {e:?}"),
                );
                failed = true;
            }
            Err(join) => {
                // the blocking task itself died — treat like a save failure
                emit_event(
                    &s.activity,
                    format!("{ip} save failed for {raw_name:?}: {join}"),
                );
                failed = true;
            }
        }
    }
    if saved > 0 {
        (StatusCode::OK, "OK").into_response()
    } else if failed {
        (StatusCode::INTERNAL_SERVER_ERROR, "Save failed").into_response()
    } else {
        (StatusCode::BAD_REQUEST, "No file saved").into_response()
    }
}

// --- Sealed endpoints (encrypted mode) ---------------------------------------
//
// All sealed endpoints are POST with body = request envelope
// ('L' ‖ ephPub ‖ nonce ‖ ct‖mac) and answer with a response envelope
// ('L' ‖ nonce ‖ ct‖mac). Decrypt first, then delegate into the same
// logic as the plaintext endpoints. AEAD failure -> plain 400 (there is
// no authenticated channel to seal an error into).
//
//   /supload  plaintext = boundary "\r\n" + multipart body
//   /sfiles   plaintext = empty            -> sealed JSON listing
//   /sls      plaintext = UTF-8 dir path   -> sealed JSON listing
//   /sfl      plaintext = UTF-8 file path  -> sealed file bytes

/// Open a sealed request envelope; None on malformed/AEAD failure.
fn open_sealed(s: &AppState, body: &[u8]) -> Option<(Vec<u8>, [u8; 32], crypto::HostKey)> {
    let host = s.host_key.as_ref()?.clone();
    let plain = crypto::open_request(body, &host)?;
    let eph = crypto::eph_public_key_of(body);
    Some((plain, eph, host))
}

fn sealed_response(host: &crypto::HostKey, eph: &[u8; 32], payload: Vec<u8>) -> Response<Body> {
    let sealed = crypto::seal_response(&payload, eph, host);
    ([(CONTENT_TYPE, "application/octet-stream")], sealed).into_response()
}

fn bad_envelope() -> Response<Body> {
    (StatusCode::BAD_REQUEST, "bad envelope").into_response()
}

async fn sealed_upload(
    State(s): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    req: Request,
) -> Response<Body> {
    // Pre-read rejection: a sealed envelope is exactly its plaintext plus a
    // 61-byte header, so the upload size can be checked on the wire size
    // alone, without decryption — the body is never buffered for oversized
    // uploads (the Bytes extractor would otherwise read it whole).
    let envelope_overhead = (crypto::HEADER_LEN + crypto::MAC_LEN) as u64;
    if s.max_upload_bytes > 0 {
        let over = req
            .headers()
            .get(CONTENT_LENGTH)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<u64>().ok())
            .is_some_and(|cl| cl > s.max_upload_bytes + envelope_overhead);
        if over {
            return (StatusCode::PAYLOAD_TOO_LARGE, "Payload too large").into_response();
        }
    }
    let Ok(body) = axum::body::to_bytes(req.into_body(), usize::MAX).await else {
        return bad_envelope();
    };
    let body = body.to_vec();
    let Some((plain, eph, host)) = open_sealed(&s, &body) else {
        return bad_envelope();
    };
    // Authoritative check on the decrypted payload (app parity — the app
    // host's maxUploadBytes applies to the decrypted payload); the pre-read
    // envelope-size check usually catches it first.
    if s.max_upload_bytes > 0 && plain.len() as u64 > s.max_upload_bytes {
        return (StatusCode::PAYLOAD_TOO_LARGE, "Payload too large").into_response();
    }
    // First line of the plaintext is the multipart boundary.
    let Some(sep) = plain.iter().position(|&b| b == 0x0d) else {
        return (StatusCode::BAD_REQUEST, "bad request").into_response();
    };
    if plain.get(sep + 1) != Some(&0x0a) {
        return (StatusCode::BAD_REQUEST, "bad request").into_response();
    }
    let Ok(boundary) = std::str::from_utf8(&plain[..sep]) else {
        return (StatusCode::BAD_REQUEST, "bad request").into_response();
    };
    // The boundary is re-embedded into a synthetic Content-Type header below,
    // bypassing the wire-level header validation that protects the plaintext
    // path — so it must be RFC 7565 bchars (1..=70, no quotes), rejected
    // here, never panicked on inside the header builder.
    if boundary.is_empty()
        || boundary.len() > 70
        || !boundary.bytes().all(|b| {
            b.is_ascii_alphanumeric() || matches!(b, b'\'' | b'(' | b')' | b'+' | b'_' | b',' | b'-' | b'.' | b'/' | b':' | b'=' | b'?' | b' ')
        })
    {
        return (StatusCode::BAD_REQUEST, "bad request").into_response();
    }
    // Re-run the decrypted body through the ordinary multipart upload path:
    // the decrypted filename still goes through safe_name (SPEC rule 1).
    let req = Request::builder()
        .method("POST")
        .header(CONTENT_TYPE, format!("multipart/form-data; boundary={boundary}"))
        .body(Body::from(plain[sep + 2..].to_vec()));
    let Ok(req) = req else {
        return (StatusCode::BAD_REQUEST, "bad request").into_response();
    };
    // the sealed route disabled the body limit; carry that over to the
    // re-parsed multipart request (no upload size limit, see SPEC.md)
    let mut req = req;
    req.extensions_mut().insert(DefaultBodyLimit::disable());
    let Ok(multipart) = Multipart::from_request(req, &s).await else {
        return (StatusCode::BAD_REQUEST, "bad request").into_response();
    };
    let resp = save_multipart(s, ip, multipart).await;
    if resp.status() == StatusCode::OK {
        sealed_response(&host, &eph, b"OK".to_vec())
    } else {
        resp // save failure (500) or nothing saved (400): plain, unsealed
    }
}

async fn sealed_list_root(State(s): State<Arc<AppState>>, body: axum::body::Bytes) -> Response<Body> {
    let Some((plain, eph, host)) = open_sealed(&s, &body) else {
        return bad_envelope();
    };
    // sfiles carries an EMPTY plaintext by contract. The endpoint is not
    // authenticated (no AAD), so a non-empty plaintext means the envelope was
    // redirected from another endpoint by a path-rewriting MITM — reject:
    // every cross-endpoint splice must fail with a visible 4xx, never 200,
    // or the client would believe a dropped upload succeeded.
    if !plain.is_empty() {
        return (StatusCode::BAD_REQUEST, "bad request").into_response();
    }
    let json = listing_json_for(s.upload_dir.clone(), s.upload_real.clone()).await;
    sealed_response(&host, &eph, json.into_bytes())
}

async fn sealed_list_subdir(
    State(s): State<Arc<AppState>>,
    body: axum::body::Bytes,
) -> Response<Body> {
    let Some((plain, eph, host)) = open_sealed(&s, &body) else {
        return bad_envelope();
    };
    // The sealed plaintext carries the path VERBATIM (not URL-encoded like
    // the plaintext routes), so sanitize without percent-decoding.
    let Ok(rel) = std::str::from_utf8(&plain).map(str::to_owned) else {
        return (StatusCode::BAD_REQUEST, "bad request").into_response();
    };
    let dir = s.upload_dir.clone();
    let real = s.upload_real.clone();
    let listed = tokio::task::spawn_blocking(move || -> Option<String> {
        let mut dir = dir;
        for part in rel.split('/') {
            match security::safe_path_component_raw(part) {
                Some(p) => dir.push(p),
                None => return None,
            }
        }
        if !security::inside_uploads(&dir, &real) || !dir.is_dir() {
            return None;
        }
        Some(listing::entries_json(&listing::list_dir(&dir, &real)))
    })
    .await
    .ok()
    .flatten();
    match listed {
        Some(json) => sealed_response(&host, &eph, json.into_bytes()),
        None => (StatusCode::NOT_FOUND, "not found").into_response(),
    }
}

async fn sealed_download(
    State(s): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    body: axum::body::Bytes,
) -> Response<Body> {
    let Some((plain, eph, host)) = open_sealed(&s, &body) else {
        return bad_envelope();
    };
    let Ok(rel) = std::str::from_utf8(&plain).map(str::to_owned) else {
        return (StatusCode::BAD_REQUEST, "bad request").into_response();
    };
    let dir = s.upload_dir.clone();
    let real = s.upload_real.clone();
    let path = tokio::task::spawn_blocking(move || {
        security::download_lookup_raw(&rel, &dir, &real)
    })
    .await
    .ok()
    .flatten();
    let Some(path) = path else {
        return (StatusCode::NOT_FOUND, "not found").into_response();
    };
    let Ok(data) = tokio::fs::read(&path).await else {
        return (StatusCode::NOT_FOUND, "not found").into_response();
    };
    let len = data.len();
    let fname = path
        .file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_default();
    emit_event(&s.activity, format!("{ip} downloaded {fname} ({len} B)"));
    sealed_response(&host, &eph, data)
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::Request;
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    fn test_state(tag: &str) -> (Arc<AppState>, PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "landir-server-test-{}-{}-{:x}",
            tag,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let real = std::fs::canonicalize(&dir).unwrap();
        // secret mode is the default; a "plain*" tag means --insecure
        let token = if tag.starts_with("plain") {
            None
        } else {
            Some("testtoken123".to_string())
        };
        let paths = Paths::new(token.as_deref());
        (
            Arc::new(AppState {
                upload_dir: dir.clone(),
                upload_real: real,
                token,
                paths,
                activity: ActivityLog::new(),
                encrypted: false,
                host_key: None,
                max_upload_bytes: 0,
            }),
            dir,
        )
    }

    /// A plaintext-mode state with --max-upload set.
    fn test_state_limited(tag: &str, max_upload: u64) -> (Arc<AppState>, PathBuf) {
        let (mut state, dir) = test_state(&format!("plain-{tag}"));
        Arc::get_mut(&mut state).unwrap().max_upload_bytes = max_upload;
        (state, dir)
    }

    /// An encrypted-mode state: no token, fixed host key (fixed seed so the
    /// sealed envelopes in tests are reproducible).
    fn test_state_encrypted(tag: &str) -> (Arc<AppState>, PathBuf) {
        let (mut state, dir) = test_state(&format!("plain-{tag}"));
        let mut seed = [0u8; 32];
        for (i, b) in seed.iter_mut().enumerate() {
            *b = i as u8;
        }
        Arc::get_mut(&mut state).unwrap().encrypted = true;
        Arc::get_mut(&mut state).unwrap().host_key = Some(crate::crypto::host_key_from_seed(seed));
        (state, dir)
    }

    fn host_pub_of(state: &AppState) -> [u8; 32] {
        *state.host_key.as_ref().unwrap().public.as_bytes()
    }

    /// POST a sealed request envelope; on 200 opens the sealed response.
    async fn sealed_post(
        app: &Router,
        uri: &str,
        plaintext: &[u8],
        host_pub: &[u8; 32],
    ) -> (StatusCode, Option<Vec<u8>>) {
        let (env, eph_seed) = crate::crypto::seal_request(plaintext, host_pub).unwrap();
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(uri)
                    .header(CONTENT_TYPE, "application/octet-stream")
                    .header(CONTENT_LENGTH, env.len()) // every real client sends it
                    .body(Body::from(env))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = resp.status();
        let body = resp.into_body().collect().await.unwrap().to_bytes();
        let opened = if status == StatusCode::OK {
            crate::crypto::open_response(&body, &eph_seed, host_pub)
        } else {
            None
        };
        (status, opened)
    }

    fn sealed_upload_body(boundary: &str, filename: &str, content: &[u8]) -> Vec<u8> {
        // sealed plaintext = boundary "\r\n" + multipart body
        let mut out = boundary.as_bytes().to_vec();
        out.extend_from_slice(b"\r\n");
        out.extend_from_slice(&multipart_body(boundary, filename, content));
        out
    }

    async fn body_string(resp: Response<Body>) -> String {
        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        String::from_utf8(bytes.to_vec()).unwrap()
    }

    fn multipart_body(boundary: &str, filename: &str, content: &[u8]) -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n"
            )
            .as_bytes(),
        );
        body.extend_from_slice(content);
        body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
        body
    }

    fn post_upload(uri: &str, boundary: &str, filename: &str, content: &[u8]) -> Request<Body> {
        let body = multipart_body(boundary, filename, content);
        Request::builder()
            .method("POST")
            .uri(uri)
            .header(CONTENT_TYPE, format!("multipart/form-data; boundary={boundary}"))
            .header(CONTENT_LENGTH, body.len()) // every real client sends it
            .body(Body::from(body))
            .unwrap()
    }

    #[tokio::test]
    async fn page_and_index_served() {
        let (state, _d) = test_state("plain");
        let app = router(state);
        for uri in ["/", "/index.html"] {
            let resp = app.clone().oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap()).await.unwrap();
            assert_eq!(resp.status(), StatusCode::OK, "uri={uri}");
        }
    }

    #[tokio::test]
    async fn unknown_path_404() {
        let (state, _d) = test_state("plain");
        let resp = router(state)
            .oneshot(Request::builder().uri("/nope").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn upload_list_download_roundtrip() {
        let (state, dir) = test_state("plain-roundtrip");
        let app = router(state);
        let resp = app
            .clone()
            .oneshot(post_upload("/upload", "BB", "hello.txt", b"hello rust"))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(body_string(resp).await, "OK");
        assert_eq!(std::fs::read(dir.join("hello.txt")).unwrap(), b"hello rust");

        let resp = app
            .clone()
            .oneshot(Request::builder().uri("/files").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body = body_string(resp).await;
        assert!(body.contains("\"name\": \"hello.txt\""), "body={body}");

        let resp = app
            .oneshot(Request::builder().uri("/fl/hello.txt").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(body_string(resp).await, "hello rust");
    }

    #[tokio::test]
    async fn upload_same_name_twice_keeps_both() {
        // rapid re-upload of the same name (same second) must not overwrite
        // or lose either version
        let (state, dir) = test_state("plain-twice");
        let app = router(state);
        for content in [b"version-1".as_slice(), b"version-2"] {
            let resp = app
                .clone()
                .oneshot(post_upload("/upload", "BB", "doc.bin", content))
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::OK);
        }
        let mut files: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|f| f.starts_with("doc"))
            .collect();
        files.sort();
        assert_eq!(files.len(), 2, "files={files:?}");
        let mut contents: Vec<Vec<u8>> =
            files.iter().map(|f| std::fs::read(dir.join(f)).unwrap()).collect();
        contents.sort();
        assert_eq!(contents, vec![b"version-1".to_vec(), b"version-2".to_vec()]);
    }

    #[tokio::test]
    async fn concurrent_same_name_uploads_never_collide() {
        // SPEC rule 4: exclusive publish + suffix re-roll means N tasks
        // uploading the same name must yield N distinct files, each
        // content preserved exactly once
        let (state, dir) = test_state("plain-concurrent");
        let app = std::sync::Arc::new(router(state));
        let mut handles = Vec::new();
        for i in 0..8 {
            let app = std::sync::Arc::clone(&app);
            handles.push(tokio::spawn(async move {
                let resp = app
                    .as_ref()
                    .clone()
                    .oneshot(post_upload(
                        "/upload",
                        "BB",
                        "race.bin",
                        format!("payload-{i}").as_bytes(),
                    ))
                    .await
                    .unwrap();
                assert_eq!(resp.status(), StatusCode::OK);
            }));
        }
        for h in handles {
            h.await.unwrap();
        }
        let mut files: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|f| f.starts_with("race"))
            .collect();
        files.sort();
        assert_eq!(files.len(), 8, "files={files:?}");
        let mut contents: Vec<Vec<u8>> =
            files.iter().map(|f| std::fs::read(dir.join(f)).unwrap()).collect();
        contents.sort();
        let mut expected: Vec<Vec<u8>> =
            (0..8).map(|i| format!("payload-{i}").into_bytes()).collect();
        expected.sort();
        assert_eq!(contents, expected);
    }

    #[tokio::test]
    async fn upload_traversal_lands_inside() {
        let (state, dir) = test_state("plain-trav");
        let resp = router(state)
            .oneshot(post_upload("/upload", "BB", "../../pwn", b"x"))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert!(dir.join("pwn").exists());
        assert!(!dir.join("../../pwn").exists());
    }

    #[tokio::test]
    async fn download_rejects_traversal_and_hidden() {
        let (state, _d) = test_state("plain-dl");
        let app = router(state);
        for uri in ["/fl/..%2f..%2fetc%2fpasswd", "/fl/.bashrc", "/fl/nope.txt"] {
            let resp = app
                .clone()
                .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::NOT_FOUND, "uri={uri}");
        }
    }

    #[tokio::test]
    async fn ls_lists_subdirectory() {
        let (state, dir) = test_state("plain-ls");
        std::fs::create_dir(dir.join("sub")).unwrap();
        std::fs::write(dir.join("sub").join("inner.txt"), b"x").unwrap();
        let app = router(state);
        let resp = app
            .clone()
            .oneshot(Request::builder().uri("/ls/sub").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert!(body_string(resp).await.contains("inner.txt"));
        let resp = app
            .oneshot(Request::builder().uri("/ls/..%2f..%2fetc").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn activity_tracks_presence_and_events() {
        let (state, _d) = test_state("plain-act");
        let app = router(state.clone());
        let addr = SocketAddr::from(([127, 0, 0, 1], 40000));
        let with_ip = |mut req: Request<Body>| {
            req.extensions_mut().insert(ConnectInfo(addr));
            req
        };
        let resp = app
            .clone()
            .oneshot(with_ip(post_upload("/upload", "BB", "a.txt", b"abc")))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let resp = app
            .clone()
            .oneshot(with_ip(
                Request::builder().uri("/files").body(Body::empty()).unwrap(),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let resp = app
            .clone()
            .oneshot(with_ip(
                Request::builder().uri("/fl/a.txt").body(Body::empty()).unwrap(),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let resp = app
            .oneshot(with_ip(
                Request::builder().uri("/fl/nope.txt").body(Body::empty()).unwrap(),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);

        let events: Vec<String> = state
            .activity
            .events()
            .iter()
            .map(|(_, t)| t.clone())
            .collect();
        assert!(
            events.iter().any(|e| e == "127.0.0.1 uploaded a.txt (3 B)"),
            "{events:?}"
        );
        assert!(
            events
                .iter()
                .any(|e| e == "127.0.0.1 downloaded a.txt (3 B)"),
            "{events:?}"
        );
        // listing polls are not logged, but they refreshed presence
        assert!(!events.iter().any(|e| e.contains("/files")), "{events:?}");
        assert!(
            events
                .iter()
                .any(|e| e == "127.0.0.1 GET /fl/nope.txt -> 404"),
            "{events:?}"
        );
        assert_eq!(
            state.activity.online(),
            vec![IpAddr::from([127, 0, 0, 1])]
        );
    }

    #[tokio::test]
    async fn upload_leaves_no_staging_files() {
        // the body is staged in a hidden temp file and published atomically:
        // nothing lingers besides the final name
        let (state, dir) = test_state("plain-atomic");
        let app = router(state);
        let resp = app
            .oneshot(post_upload("/upload", "BB", "atomic.txt", b"fully written"))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(std::fs::read(dir.join("atomic.txt")).unwrap(), b"fully written");
        let names: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert!(
            !names.iter().any(|n| n.starts_with(".landir_tmp")),
            "staging files must not linger after publish: {names:?}"
        );
    }

    #[tokio::test]
    async fn listing_hides_hidden_names() {
        // dot-prefixed files (incl. any in-flight staging temps) never
        // appear in the /files listing and are not downloadable
        let (state, dir) = test_state("plain-hidden");
        std::fs::write(dir.join(".hidden.txt"), b"secret").unwrap();
        let app = router(state);
        let resp = app
            .clone()
            .oneshot(post_upload("/upload", "BB", "shown.txt", b"data"))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let resp = app
            .clone()
            .oneshot(Request::builder().uri("/files").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body = body_string(resp).await;
        assert!(body.contains("\"name\": \"shown.txt\""), "body={body}");
        assert!(!body.contains(".hidden.txt"), "body={body}");
        let resp = app
            .oneshot(Request::builder().uri("/fl/.hidden.txt").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn upload_save_failure_is_500_with_event() {
        // a server-side save failure (uploads dir gone) must surface as a
        // 500 with an event — not as a client-error 400
        let (state, dir) = test_state("plain-savefail");
        let app = router(state.clone());
        std::fs::remove_dir_all(&dir).unwrap();
        let resp = app
            .oneshot(post_upload("/upload", "BB", "fail.txt", b"x"))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(body_string(resp).await, "Save failed");
        let events: Vec<String> = state
            .activity
            .events()
            .iter()
            .map(|(_, t)| t.clone())
            .collect();
        assert!(
            events.iter().any(|e| e.contains("save failed for \"fail.txt\"")),
            "{events:?}"
        );
    }

    #[tokio::test]
    async fn unmatched_paths_are_tracked() {
        // axum's default 404 fallback is not layered: an explicit fallback
        // must keep scanner probes / wrong URLs visible (presence + event)
        let (state, _d) = test_state("plain-unmatched");
        let app = router(state.clone());
        let addr = SocketAddr::from(([127, 0, 0, 1], 41001));
        let mut req = Request::builder().uri("/nope").body(Body::empty()).unwrap();
        req.extensions_mut().insert(ConnectInfo(addr));
        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
        let events: Vec<String> = state
            .activity
            .events()
            .iter()
            .map(|(_, t)| t.clone())
            .collect();
        assert!(
            events.iter().any(|e| e == "127.0.0.1 GET /nope -> 404"),
            "{events:?}"
        );
        assert_eq!(
            state.activity.online(),
            vec![IpAddr::from([127, 0, 0, 1])]
        );
    }

    #[tokio::test]
    async fn bare_token_redirect_refreshes_presence_without_event() {
        // the redirect route is registered before the activity layer, so it
        // refreshes presence; like landir.py it stays silent (no send_error)
        let (state, _d) = test_state("secret-track");
        let app = router(state.clone());
        let addr = SocketAddr::from(([127, 0, 0, 1], 41002));
        let mut req = Request::builder()
            .uri("/testtoken123")
            .body(Body::empty())
            .unwrap();
        req.extensions_mut().insert(ConnectInfo(addr));
        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::FOUND);
        assert_eq!(
            state.activity.online(),
            vec![IpAddr::from([127, 0, 0, 1])]
        );
        assert!(state.activity.events().is_empty(), "redirect must stay quiet");
    }

    #[tokio::test]
    async fn index_html_refreshes_presence() {
        // insecure mode: /index.html was registered after the layer before
        // and escaped tracking; it must refresh presence like the page
        let (state, _d) = test_state("plain-index");
        let app = router(state.clone());
        let addr = SocketAddr::from(([127, 0, 0, 1], 41003));
        let mut req = Request::builder()
            .uri("/index.html")
            .body(Body::empty())
            .unwrap();
        req.extensions_mut().insert(ConnectInfo(addr));
        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(
            state.activity.online(),
            vec![IpAddr::from([127, 0, 0, 1])]
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn symlink_escape_endpoints_404() {
        // endpoints must not serve (or even list) a symlink that resolves
        // outside the uploads dir
        let (state, dir) = test_state("plain-symlink");
        std::os::unix::fs::symlink("/etc/hostname", dir.join("evil.txt")).unwrap();
        std::os::unix::fs::symlink("/etc", dir.join("etcdir")).unwrap();
        let app = router(state);
        for uri in ["/fl/evil.txt", "/ls/etcdir", "/fl/etcdir/passwd"] {
            let resp = app
                .clone()
                .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::NOT_FOUND, "uri={uri}");
        }
        let resp = app
            .oneshot(Request::builder().uri("/files").body(Body::empty()).unwrap())
            .await
            .unwrap();
        let body = body_string(resp).await;
        assert!(!body.contains("evil.txt"), "body={body}");
        assert!(!body.contains("etcdir"), "body={body}");
    }

    #[tokio::test]
    async fn encrypted_mode_plaintext_routes_are_blind_404() {
        let (state, _d) = test_state_encrypted("404");
        let app = router(state);
        // every plaintext route (page included) 404s: files are not readable
        // or writable without the host key
        for req in [
            Request::builder().uri("/").body(Body::empty()).unwrap(),
            Request::builder().uri("/index.html").body(Body::empty()).unwrap(),
            Request::builder().uri("/files").body(Body::empty()).unwrap(),
            Request::builder().uri("/fl/x").body(Body::empty()).unwrap(),
            Request::builder().uri("/ls/sub").body(Body::empty()).unwrap(),
            post_upload("/upload", "BB", "a.txt", b"x"),
            Request::builder().method("POST").uri("/snope").body(Body::from("x")).unwrap(),
        ] {
            let resp = app.clone().oneshot(req).await.unwrap();
            assert_eq!(resp.status(), StatusCode::NOT_FOUND, "{:?}", resp.status());
        }
    }

    #[tokio::test]
    async fn encrypted_sealed_upload_list_download_roundtrip() {
        let (state, dir) = test_state_encrypted("roundtrip");
        let host_pub = host_pub_of(&state);
        let app = router(state);
        let (status, opened) = sealed_post(
            &app,
            "/supload",
            &sealed_upload_body("BB", "hello.txt", b"sealed hello"),
            &host_pub,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(opened.as_deref(), Some(b"OK".as_slice()));
        assert_eq!(std::fs::read(dir.join("hello.txt")).unwrap(), b"sealed hello");

        let (status, opened) = sealed_post(&app, "/sfiles", b"", &host_pub).await;
        assert_eq!(status, StatusCode::OK);
        let listing = String::from_utf8(opened.unwrap()).unwrap();
        assert!(listing.contains("\"name\": \"hello.txt\""), "{listing}");

        let (status, opened) = sealed_post(&app, "/sfl", b"hello.txt", &host_pub).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(opened.unwrap(), b"sealed hello");
    }

    #[tokio::test]
    async fn encrypted_sealed_subdir_listing_and_download() {
        let (state, dir) = test_state_encrypted("subdir");
        std::fs::create_dir(dir.join("sub")).unwrap();
        std::fs::write(dir.join("sub").join("inner.txt"), b"inner content").unwrap();
        let host_pub = host_pub_of(&state);
        let app = router(state);
        let (status, opened) = sealed_post(&app, "/sls", b"sub", &host_pub).await;
        assert_eq!(status, StatusCode::OK);
        assert!(String::from_utf8(opened.unwrap()).unwrap().contains("inner.txt"));
        let (status, opened) = sealed_post(&app, "/sfl", b"sub/inner.txt", &host_pub).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(opened.unwrap(), b"inner content");
        // traversal / hidden / missing paths inside sealed bodies -> 404
        for plain in [b"../main.rs".as_slice(), b".hidden", b"nope.txt", b"sub/../../main.rs"] {
            let (status, _) = sealed_post(&app, "/sfl", plain, &host_pub).await;
            assert_eq!(status, StatusCode::NOT_FOUND, "plain={plain:?}");
        }
        let (status, _) = sealed_post(&app, "/sls", b"../../etc", &host_pub).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn encrypted_sealed_traversal_lands_inside() {
        // SPEC rule 1 below the crypto layer: a traversal filename inside a
        // sealed upload body is sanitized exactly like a plaintext one
        let (state, dir) = test_state_encrypted("trav");
        let host_pub = host_pub_of(&state);
        let app = router(state);
        let (status, opened) = sealed_post(
            &app,
            "/supload",
            &sealed_upload_body("BB", "../../pwn", b"pwned"),
            &host_pub,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(opened.as_deref(), Some(b"OK".as_slice()));
        assert_eq!(std::fs::read(dir.join("pwn")).unwrap(), b"pwned");
    }

    #[tokio::test]
    async fn encrypted_sealed_bad_envelopes_400() {
        let (state, _d) = test_state_encrypted("badenv");
        let host_pub = host_pub_of(&state);
        let app = router(state);
        let (env, _eph) = crate::crypto::seal_request(b"x", &host_pub).unwrap();
        let mut cases: Vec<Vec<u8>> = vec![
            b"garbage".to_vec(),
            Vec::new(),
            env[..env.len() - 3].to_vec(),
            {
                let mut v = env.clone();
                v[0] = 0x4d; // wrong version byte
                v
            },
            {
                let mut v = env.clone();
                let n = v.len();
                v[n - 1] ^= 1; // tampered mac
                v
            },
        ];
        // envelope sealed to a DIFFERENT host key also fails AEAD here
        let other_pub = crate::crypto::x25519_base(&[9u8; 32]);
        let (foreign, _) = crate::crypto::seal_request(b"x", &other_pub).unwrap();
        cases.push(foreign);
        for payload in cases {
            let resp = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/sfiles")
                        .header(CONTENT_TYPE, "application/octet-stream")
                        .body(Body::from(payload))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
        }
    }

    #[tokio::test]
    async fn encrypted_sealed_upload_without_file_400() {
        let (state, _d) = test_state_encrypted("nofile");
        let host_pub = host_pub_of(&state);
        let app = router(state);
        let body = b"BB\r\n--BB--\r\n".to_vec(); // boundary line, no file part
        let (status, _) = sealed_post(&app, "/supload", &body, &host_pub).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        // no CRLF boundary line at all
        let (status, _) = sealed_post(&app, "/supload", b"no boundary line", &host_pub).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn encrypted_sealed_upload_rejects_invalid_boundaries() {
        // the boundary is re-embedded into a synthetic Content-Type header:
        // control chars / quotes / oversize must 400, never panic the builder
        let (state, _d) = test_state_encrypted("badbound");
        let host_pub = host_pub_of(&state);
        let app = router(state);
        for bad in [
            &b"\r\n--x--\r\n"[..],              // empty boundary line
            b"b\x1b[2Jad\r\n--x--\r\n",          // ESC in the boundary
            b"quo\"te\r\n--x--\r\n",             // quote confuses the header
            b"with\rnewline\r\n--x--\r\n",       // CR inside (first \r wins)
            format!("{}\r\n--x--\r\n", "L".repeat(71)).as_bytes(), // > 70
        ] {
            let (status, _) = sealed_post(&app, "/supload", bad, &host_pub).await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "bad={:?}", &bad[..bad.len().min(12)]);
        }
    }

    #[tokio::test]
    async fn encrypted_sealed_listing_hides_hidden_names() {
        let (state, dir) = test_state_encrypted("hidden");
        std::fs::write(dir.join(".hidden.txt"), b"secret").unwrap();
        let host_pub = host_pub_of(&state);
        let app = router(state.clone());
        let (status, _) = sealed_post(
            &app,
            "/supload",
            &sealed_upload_body("BB", "shown.txt", b"data"),
            &host_pub,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let (status, opened) = sealed_post(&app, "/sfiles", b"", &host_pub).await;
        assert_eq!(status, StatusCode::OK);
        let listing = String::from_utf8(opened.unwrap()).unwrap();
        assert!(listing.contains("shown.txt"), "{listing}");
        assert!(!listing.contains(".hidden.txt"), "{listing}");
    }

    #[tokio::test]
    async fn encrypted_sealed_events_logged() {
        let (state, _d) = test_state_encrypted("events");
        let host_pub = host_pub_of(&state);
        let app = router(state.clone());
        let (status, _) = sealed_post(
            &app,
            "/supload",
            &sealed_upload_body("BB", "evt.txt", b"abc"),
            &host_pub,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let (status, _) = sealed_post(&app, "/sfl", b"evt.txt", &host_pub).await;
        assert_eq!(status, StatusCode::OK);
        let events: Vec<String> = state.activity.events().iter().map(|(_, t)| t.clone()).collect();
        assert!(events.iter().any(|e| e.contains("uploaded evt.txt (3 B)")), "{events:?}");
        assert!(events.iter().any(|e| e.contains("downloaded evt.txt (3 B)")), "{events:?}");
    }

    #[tokio::test]
    async fn encrypted_sealed_endpoint_splices_rejected() {
        // The endpoint is not authenticated (no AAD): a path-rewriting MITM
        // can post a valid sealed envelope to a different sealed endpoint.
        // Every cross-endpoint splice must fail with a visible 4xx — a 200
        // would make the client believe a dropped upload succeeded (or save
        // a listing as the downloaded file).
        let (state, dir) = test_state_encrypted("splice");
        std::fs::create_dir(dir.join("sub")).unwrap();
        std::fs::write(dir.join("notes.txt"), b"my notes").unwrap();
        let host_pub = host_pub_of(&state);
        let app = router(state);
        let upload_plain = sealed_upload_body("BB", "report.pdf", b"quarterly report");
        for (name, intended, plaintext) in [
            ("upload", "/supload", upload_plain.as_slice()),
            ("root-listing", "/sfiles", b""),
            ("sub-listing", "/sls", b"sub"),
            ("download", "/sfl", b"notes.txt"),
        ] {
            for target in ["/supload", "/sfiles", "/sls", "/sfl"] {
                let (status, _) = sealed_post(&app, target, plaintext, &host_pub).await;
                if target == intended {
                    assert_eq!(status, StatusCode::OK, "{name} -> {target}");
                } else {
                    assert!(
                        status == StatusCode::BAD_REQUEST || status == StatusCode::NOT_FOUND,
                        "{name} redirected to {target} answered {status}"
                    );
                }
            }
        }
    }

    #[tokio::test]
    async fn max_upload_over_limit_413_not_saved() {
        let (state, dir) = test_state_limited("over", 1000);
        let app = router(state);
        let resp = app
            .oneshot(post_upload("/upload", "BB", "big.bin", &[7u8; 2000]))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE);
        assert!(!dir.join("big.bin").exists());
    }

    #[tokio::test]
    async fn max_upload_rejects_on_the_header_before_the_body() {
        // the 413 must come from the Content-Length header alone — a server
        // that reads first would buffer the promised body
        let (state, _d) = test_state_limited("preread", 1000);
        let app = router(state);
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/upload")
                    .header(CONTENT_TYPE, "multipart/form-data; boundary=B")
                    .header(CONTENT_LENGTH, "999999") // promised, never sent
                    .body(Body::from(b"--B\r\n".to_vec())) // a sliver only
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE);
    }

    #[tokio::test]
    async fn max_upload_under_limit_still_saves() {
        let (state, dir) = test_state_limited("under", 1000);
        let app = router(state);
        let resp = app
            .oneshot(post_upload("/upload", "BB", "small.txt", &[3u8; 200]))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert!(dir.join("small.txt").exists());
    }

    #[tokio::test]
    async fn max_upload_sealed_over_limit_413_not_saved() {
        // the envelope is plaintext + 61 bytes: 2000 > 1000 must be rejected
        // on the wire size alone, before the envelope is buffered or opened
        let (mut state, dir) = test_state_encrypted("sover");
        Arc::get_mut(&mut state).unwrap().max_upload_bytes = 1000;
        let host_pub = host_pub_of(&state);
        let app = router(state);
        let (status, _) = sealed_post(
            &app,
            "/supload",
            &sealed_upload_body("BB", "big.bin", &[7u8; 2000]),
            &host_pub,
        )
        .await;
        assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
        assert!(!dir.join("big.bin").exists());
    }

    #[tokio::test]
    async fn max_upload_sealed_just_under_limit_ok() {
        let (mut state, dir) = test_state_encrypted("sunder");
        Arc::get_mut(&mut state).unwrap().max_upload_bytes = 1000;
        let host_pub = host_pub_of(&state);
        let app = router(state);
        let (status, opened) = sealed_post(
            &app,
            "/supload",
            &sealed_upload_body("BB", "edge.bin", &[7u8; 800]), // + framing < 1000
            &host_pub,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(opened.as_deref(), Some(b"OK".as_slice()));
        assert!(dir.join("edge.bin").exists());
    }

    #[tokio::test]
    async fn secret_mode_gates_everything() {        let (state, _d) = test_state("secret");
        let app = router(state);
        // bare paths are hidden
        for req in [
            Request::builder().uri("/").body(Body::empty()).unwrap(),
            post_upload("/upload", "BB", "a.txt", b"x"),
        ] {
            let resp = app.clone().oneshot(req).await.unwrap();
            assert_eq!(resp.status(), StatusCode::NOT_FOUND);
        }
        // bare token redirects to the page
        let resp = app
            .clone()
            .oneshot(Request::builder().uri("/testtoken123").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::FOUND);
        // token paths work
        let resp = app
            .clone()
            .oneshot(Request::builder().uri("/testtoken123/").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let resp = app
            .oneshot(post_upload("/testtoken123/upload", "BB", "a.txt", b"x"))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }
}
