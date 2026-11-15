//! Route path shapes, secret (default) and --insecure variants.

#[derive(Clone, Debug)]
pub struct Paths {
    pub page: String,
    pub upload: String,
    pub files: String,
    pub fl_prefix: String,
    pub ls_prefix: String,
}

impl Paths {
    pub fn new(token: Option<&str>) -> Self {
        match token {
            Some(t) => Self {
                page: format!("/{t}/"),
                upload: format!("/{t}/upload"),
                files: format!("/{t}/files"),
                fl_prefix: format!("/{t}/fl/"),
                ls_prefix: format!("/{t}/ls/"),
            },
            None => Self {
                page: "/".to_string(),
                upload: "/upload".to_string(),
                files: "/files".to_string(),
                fl_prefix: "/fl/".to_string(),
                ls_prefix: "/ls/".to_string(),
            },
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
}
