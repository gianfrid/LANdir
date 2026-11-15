//! HTTP layer. `router` is the seam: every endpoint is reachable through it,
//! so tests exercise the whole surface with `tower::oneshot` without sockets.

use std::path::PathBuf;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::{DefaultBodyLimit, Multipart, State};
use axum::http::header::{CONTENT_DISPOSITION, CONTENT_LENGTH, CONTENT_TYPE};
use axum::http::{Response, StatusCode, Uri};
use axum::response::{Html, IntoResponse};
use axum::routing::{get, post};
use axum::Router;
use tokio_util::io::ReaderStream;

use crate::listing;
use crate::page::PAGE;
use crate::paths::Paths;
use crate::security;

pub struct AppState {
    pub upload_dir: PathBuf,
    pub upload_real: PathBuf,
    pub token: Option<String>,
    pub paths: Paths,
}

pub fn router(state: Arc<AppState>) -> Router {
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
    app.with_state(state)
}

async fn serve_page() -> Html<&'static str> {
    Html(PAGE)
}

fn json_response(body: String) -> Response<Body> {
    ([(CONTENT_TYPE, "application/json")], body).into_response()
}

async fn list_root(State(s): State<Arc<AppState>>) -> Response<Body> {
    json_response(listing::entries_json(&listing::list_dir(&s.upload_dir, &s.upload_real)))
}

async fn list_subdir(State(s): State<Arc<AppState>>, uri: Uri) -> Response<Body> {
    let raw = uri.path();
    let rel = raw.strip_prefix(&s.paths.ls_prefix).unwrap_or(raw);
    let rel = percent_encoding::percent_decode_str(rel).decode_utf8_lossy();
    let mut dir = s.upload_dir.clone();
    for part in rel.split('/') {
        match security::safe_path_component(part) {
            Some(p) => dir.push(p),
            None => return (StatusCode::NOT_FOUND, "not found").into_response(),
        }
    }
    if !security::inside_uploads(&dir, &s.upload_real) || !dir.is_dir() {
        return (StatusCode::NOT_FOUND, "not found").into_response();
    }
    json_response(listing::entries_json(&listing::list_dir(&dir, &s.upload_real)))
}

async fn download(State(s): State<Arc<AppState>>, uri: Uri) -> Response<Body> {
    let raw = uri.path();
    let rel = raw.strip_prefix(&s.paths.fl_prefix).unwrap_or(raw);
    let Some(path) = security::download_lookup(rel, &s.upload_dir, &s.upload_real) else {
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
    Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "application/octet-stream")
        .header(CONTENT_DISPOSITION, format!("attachment; filename=\"{fname}\""))
        .header(CONTENT_LENGTH, len)
        .body(Body::from_stream(ReaderStream::new(file)))
        .unwrap()
}

async fn upload(State(s): State<Arc<AppState>>, mut multipart: Multipart) -> Response<Body> {
    let mut saved = 0;
    while let Ok(Some(field)) = multipart.next_field().await {
        let Some(fname) = field.file_name().map(|f| f.to_string()) else {
            continue;
        };
        let Ok(data) = field.bytes().await else {
            continue;
        };
        if let Some(name) = security::safe_name(&fname, &s.upload_real) {
            if tokio::fs::write(s.upload_dir.join(&name), &data).await.is_ok() {
                saved += 1;
            }
        }
    }
    if saved > 0 {
        (StatusCode::OK, "OK").into_response()
    } else {
        (StatusCode::BAD_REQUEST, "No file saved").into_response()
    }
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
            }),
            dir,
        )
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
        Request::builder()
            .method("POST")
            .uri(uri)
            .header(CONTENT_TYPE, format!("multipart/form-data; boundary={boundary}"))
            .body(Body::from(multipart_body(boundary, filename, content)))
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
    async fn secret_mode_gates_everything() {
        let (state, _d) = test_state("secret");
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
