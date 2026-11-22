//! Full-screen terminal UI (ratatui/crossterm), used when stdout is a TTY —
//! e.g. `podman run -it`. The QR code and the list of currently-online client
//! IPs stay visible on top ('q' toggles the QR panel); a scrollable event log
//! below shows who uploaded or downloaded what. Ctrl+C quits. Without a TTY
//! the server falls back to plain log lines (see main.rs).

use std::io::{stdout, IsTerminal};
use std::time::Duration;

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::text::Line;
use ratatui::widgets::Paragraph;
use ratatui::Terminal;

use crate::activity::ActivityLog;

pub fn is_tty() -> bool {
    // A TTY alone isn't enough: distroless containers and CI runners often
    // have stdout attached to a pipe that reports as a terminal while TERM
    // is unset or "dumb", and the ANSI escapes ratatui emits would then
    // show up as raw control characters. Require a real terminal type.
    stdout().is_terminal() && term_is_usable(&std::env::var("TERM").ok())
}

/// True when TERM names a terminal type that can render ANSI escapes.
fn term_is_usable(term: &Option<String>) -> bool {
    match term {
        Some(t) => !t.is_empty() && t != "dumb",
        None => false,
    }
}

/// Strip ANSI SGR escape sequences (e.g. `\x1b[30;47m`) from a string.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            // Skip the escape sequence: ESC [ ... letter
            for c2 in chars.by_ref() {
                if c2.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

pub fn run(activity: &ActivityLog, url: &str) -> std::io::Result<()> {
    enable_raw_mode()?;
    let mut out = stdout();
    execute!(out, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(out);
    let mut terminal = Terminal::new(backend)?;
    let result = event_loop(&mut terminal, activity, url);
    // Always restore the terminal, even if the loop errored.
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    let _ = terminal.show_cursor();
    result
}

/// QR line style: black modules with no explicit background, so the
/// terminal's own background shows through the quiet zone — scannable from
/// a camera in any terminal, unlike a painted white bg that some
/// colorschemes (herdr) render black.
fn qr_line_style() -> ratatui::style::Style {
    use ratatui::style::{Color, Style};
    Style::new().fg(Color::Black)
}

fn event_loop(
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    activity: &ActivityLog,
    url: &str,
) -> std::io::Result<()> {
    // qr_terminal emits ANSI color escapes; ratatui would print them
    // literally, so strip them (matches the Python curses TUI) and re-apply
    // the same fg/bg pair as an explicit style, so the QR stays scannable
    // even when the terminal's default colors disagree with its theme.
    let qr_style = qr_line_style();
    let qr_lines: Vec<Line<'static>> = crate::qr::qr_terminal(url)
        .unwrap_or_default()
        .lines()
        .map(|l| Line::styled(strip_ansi(l), qr_style))
        .collect();
    let mut show_qr = true;
    let mut scroll: usize = 0; // log lines scrolled up from the bottom
    loop {
        if event::poll(Duration::from_millis(250))? {
            if let Event::Key(KeyEvent { code, modifiers, .. }) = event::read()? {
                match code {
                    KeyCode::Char('q') => show_qr = !show_qr,
                    KeyCode::Char('c') if modifiers.contains(KeyModifiers::CONTROL) => {
                        return Ok(())
                    }
                    KeyCode::Up => scroll += 1,
                    KeyCode::Down => scroll = scroll.saturating_sub(1),
                    KeyCode::PageUp => scroll += 10,
                    KeyCode::PageDown => scroll = scroll.saturating_sub(10),
                    _ => {}
                }
            }
        }

        let online = activity.online();
        let online_txt = if online.is_empty() {
            "-".to_string()
        } else {
            online
                .iter()
                .map(|ip| ip.to_string())
                .collect::<Vec<_>>()
                .join(", ")
        };
        let events = activity.events();
        let event_lines: Vec<Line> = events
            .iter()
            .map(|(t, txt)| {
                Line::from(format!(
                    "{}  {txt}",
                    chrono::DateTime::<chrono::Local>::from(*t).format("%H:%M:%S")
                ))
            })
            .collect();

        terminal.draw(|f| {
            let area = f.area();
            let top_h = if show_qr {
                qr_lines.len() as u16 + 3
            } else {
                3
            };
            let top_h = top_h.min(area.height.saturating_sub(3).max(3));
            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Length(top_h), Constraint::Min(3)])
                .split(area);

            let mut top: Vec<Line> = vec![Line::from(format!(
                " LANdir  {url}   (q: QR on/off, Ctrl+C: stop)"
            ))];
            if show_qr {
                top.extend(qr_lines.iter().cloned());
            }
            top.push(Line::from(format!(" Online: {online_txt}")));
            f.render_widget(Paragraph::new(top), chunks[0]);

            let log_h = chunks[1].height as usize;
            let max_scroll = event_lines.len().saturating_sub(log_h);
            let scroll = scroll.min(max_scroll);
            let end = event_lines.len() - scroll;
            let start = end.saturating_sub(log_h);
            f.render_widget(Paragraph::new(event_lines[start..end].to_vec()), chunks[1]);
        })?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn term_usable_for_real_terminal_types() {
        assert!(term_is_usable(&Some("xterm-256color".into())));
        assert!(term_is_usable(&Some("screen".into())));
        assert!(term_is_usable(&Some("linux".into())));
    }

    #[test]
    fn term_unusable_for_dumb_or_missing() {
        assert!(!term_is_usable(&Some("dumb".into())));
        assert!(!term_is_usable(&Some("".into())));
        assert!(!term_is_usable(&None));
    }

    #[test]
    fn strip_ansi_removes_sgr_sequences() {
        assert_eq!(strip_ansi("\u{1b}[30;47m█▄▀ \u{1b}[0m"), "█▄▀ ");
        assert_eq!(strip_ansi("plain text"), "plain text");
        assert_eq!(strip_ansi("\u{1b}[1;31mred\u{1b}[0m"), "red");
    }

    #[test]
    fn qr_line_style_is_black_on_transparent() {
        use ratatui::style::Color;
        let style = qr_line_style();
        assert_eq!(style.fg, Some(Color::Black));
        assert_eq!(style.bg, None); // terminal default shows through
    }

    #[test]
    fn strip_ansi_handles_edge_cases() {
        // Empty string
        assert_eq!(strip_ansi(""), "");
        // ESC at end without terminator
        assert_eq!(strip_ansi("abc\u{1b}"), "abc");
        // Multiple sequences in one line
        assert_eq!(
            strip_ansi("\u{1b}[37;40mfoo\u{1b}[0m bar \u{1b}[1mbaz\u{1b}[0m"),
            "foo bar baz"
        );
        // ESC followed by non-CSI (should be skipped up to first alpha)
        assert_eq!(strip_ansi("a\u{1b}Xb"), "ab");
        // Only escape sequences
        assert_eq!(strip_ansi("\u{1b}[0m"), "");
    }
}
