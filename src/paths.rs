//! Route path shapes, secret (default), --insecure, and --encrypt variants.

#[derive(Clone, Debug)]
pub struct Paths {
    pub page: String,
    pub upload: String,
    pub files: String,
    pub fl_prefix: String,
    pub ls_prefix: String,
    // Sealed endpoints (encrypted mode): fixed root paths, no token
    // (docs/adr/0003-sealed-app-endpoints.md, docs/adr/0004-cli-encrypted-mode.md).
    // All POST with body = request envelope ('L' ‖ ephPub ‖ nonce ‖ ct‖mac);
    // the answer is a response envelope ('L' ‖ nonce ‖ ct‖mac).
    pub supload: String,
    pub sfiles: String,
    pub sls: String,
    pub sfl: String,
}

impl Paths {
    pub fn new(token: Option<&str>) -> Self {
        let (page, upload, files, fl_prefix, ls_prefix) = match token {
            Some(t) => (
                format!("/{t}/"),
                format!("/{t}/upload"),
                format!("/{t}/files"),
                format!("/{t}/fl/"),
                format!("/{t}/ls/"),
            ),
            None => (
                "/".to_string(),
                "/upload".to_string(),
                "/files".to_string(),
                "/fl/".to_string(),
                "/ls/".to_string(),
            ),
        };
        Self {
            page,
            upload,
            files,
            fl_prefix,
            ls_prefix,
            supload: "/supload".to_string(),
            sfiles: "/sfiles".to_string(),
            sls: "/sls".to_string(),
            sfl: "/sfl".to_string(),
        }
    }

    /// Bare token path (no trailing slash); gets a 302 to the page in secret mode.
    pub fn bare_token(token: &str) -> String {
        format!("/{token}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_paths() {
        let p = Paths::new(None);
        assert_eq!(p.page, "/");
        assert_eq!(p.upload, "/upload");
        assert_eq!(p.files, "/files");
        assert_eq!(p.fl_prefix, "/fl/");
        assert_eq!(p.ls_prefix, "/ls/");
    }

    #[test]
    fn secret_paths() {
        let p = Paths::new(Some("tok123"));
        assert_eq!(p.page, "/tok123/");
        assert_eq!(p.upload, "/tok123/upload");
        assert_eq!(Paths::bare_token("tok123"), "/tok123");
    }

    #[test]
    fn sealed_paths_are_fixed_root_paths() {
        // encrypted mode has no token, so the sealed endpoints live at the
        // root — this is what the app client computes from the scanned URL
        for p in [Paths::new(None), Paths::new(Some("tok123"))] {
            assert_eq!(p.supload, "/supload");
            assert_eq!(p.sfiles, "/sfiles");
            assert_eq!(p.sls, "/sls");
            assert_eq!(p.sfl, "/sfl");
        }
    }
}
