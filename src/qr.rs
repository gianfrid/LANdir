//! QR code generation for the startup URL: encode with the `qrcode` crate
//! (byte mode, EC level M), render as ANSI half-blocks on a white background.
//!
//! Versions are capped at 6 (106 bytes), matching the Python implementation;
//! longer URLs (e.g. secret mode with an IPv6 host) print "no QR code" instead.

use qrcode::{Color, EcLevel, QrCode};

/// Encode `text` and render it as an ANSI half-block string.
pub fn qr_terminal(text: &str) -> Result<String, String> {
    let code =
        QrCode::with_error_correction_level(text.as_bytes(), EcLevel::M).map_err(|e| e.to_string())?;
    // version 6 is 41x41 modules; cap there to match the Python implementation
    if code.width() > 41 {
        return Err("text too long for QR versions 1-6".to_string());
    }
    let n = code.width();
    let colors = code.to_colors();
    let matrix: Vec<Vec<bool>> = colors
        .chunks(n)
        .map(|row| row.iter().map(|c| *c == Color::Dark).collect())
        .collect();
    Ok(render_ansi(&matrix, 4))
}

/// ANSI half-block rendering; dark modules on a white background.
fn render_ansi(matrix: &[Vec<bool>], quiet: usize) -> String {
    let n = matrix.len();
    let w = n + 2 * quiet;
    let dark = |r: usize, c: usize| -> bool {
        r >= quiet && r - quiet < n && c >= quiet && c - quiet < n && matrix[r - quiet][c - quiet]
    };
    let mut lines = Vec::new();
    let mut r = 0;
    while r < w {
        let mut line = String::from("\u{1b}[30;107m");
        for c in 0..w {
            let top = dark(r, c);
            let bottom = dark(r + 1, c);
            line.push(if top && bottom {
                '█'
            } else if top {
                '▀'
            } else if bottom {
                '▄'
            } else {
                ' '
            });
        }
        line.push_str("\u{1b}[0m");
        lines.push(line);
        r += 2;
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_url_within_version_cap() {
        let url = "http://192.168.1.10:8000/";
        let out = qr_terminal(url).unwrap();
        assert!(out.contains("\u{1b}[30;107m"));
        // deterministic
        assert_eq!(out, qr_terminal(url).unwrap());
    }

    #[test]
    fn matrix_has_spec_shape() {
        // version 1 QR is 21x21 and must have dark finder-pattern corners
        let code = QrCode::with_error_correction_level(b"hi", EcLevel::M).unwrap();
        assert_eq!(code.width(), 21); // version 1
        let colors = code.to_colors();
        assert_eq!(colors[0], Color::Dark); // top-left finder corner
        assert_eq!(colors[7], Color::Light); // separator column next to it
    }

    #[test]
    fn rejects_text_beyond_version_6() {
        let long = "x".repeat(200);
        assert!(qr_terminal(&long).is_err());
    }
}
