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
    stdout().is_terminal()
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

fn event_loop(
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    activity: &ActivityLog,
    url: &str,
) -> std::io::Result<()> {
    let qr_lines: Vec<String> = crate::qr::qr_terminal(url)
        .unwrap_or_default()
        .lines()
        .map(|l| l.to_string())
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
                " Landir  {url}   (q: QR on/off, Ctrl+C: stop)"
            ))];
            if show_qr {
                top.extend(qr_lines.iter().cloned().map(Line::from));
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
