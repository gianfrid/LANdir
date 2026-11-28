//! Client activity tracking: presence (which IPs were seen within a TTL) and
//! an event log (uploads/downloads/errors with the client IP). The container
//! has no TTY, so this is plain line logs — listing polls are never logged,
//! they only refresh presence.

use std::collections::{HashMap, VecDeque};
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

/// How long a client stays "online" after its last request.
pub const PRESENCE_TTL: Duration = Duration::from_secs(10);

/// True when events go to plain log lines; false while the ratatui UI runs
/// (the UI owns the terminal and shows events in its log pane — a stray
/// eprintln! would garble the alternate screen). Mirrors landir.py's
/// PLAIN_MODE.
static PLAIN_MODE: AtomicBool = AtomicBool::new(true);

pub fn set_plain_mode(plain: bool) {
    PLAIN_MODE.store(plain, Ordering::Relaxed);
}

pub struct ActivityLog {
    ttl: Duration,
    max_events: usize,
    last_seen: Mutex<HashMap<IpAddr, Instant>>,
    events: Mutex<VecDeque<(SystemTime, String)>>,
}

impl ActivityLog {
    pub fn new() -> Self {
        Self::with_ttl(PRESENCE_TTL)
    }

    pub fn with_ttl(ttl: Duration) -> Self {
        ActivityLog {
            ttl,
            max_events: 500,
            last_seen: Mutex::new(HashMap::new()),
            events: Mutex::new(VecDeque::new()),
        }
    }

    pub fn touch(&self, ip: IpAddr) {
        self.last_seen
            .lock()
            .unwrap()
            .insert(ip, Instant::now());
    }

    pub fn add_event(&self, text: String) {
        let mut ev = self.events.lock().unwrap();
        ev.push_back((SystemTime::now(), text));
        while ev.len() > self.max_events {
            ev.pop_front();
        }
    }

    pub fn online(&self) -> Vec<IpAddr> {
        self.online_at(Instant::now())
    }

    /// IPs seen within the TTL at [now]; expired entries are pruned.
    pub fn online_at(&self, now: Instant) -> Vec<IpAddr> {
        let mut seen = self.last_seen.lock().unwrap();
        seen.retain(|_, t| now.duration_since(*t) <= self.ttl);
        let mut ips: Vec<IpAddr> = seen.keys().copied().collect();
        ips.sort();
        ips
    }

    pub fn events(&self) -> Vec<(SystemTime, String)> {
        self.events.lock().unwrap().iter().cloned().collect()
    }
}

impl Default for ActivityLog {
    fn default() -> Self {
        Self::new()
    }
}

fn fmt_stamp(t: SystemTime) -> String {
    // Local time, like landir.py and the TUI's event pane (plain logs are
    // read by humans, not parsed).
    chrono::DateTime::<chrono::Local>::from(t)
        .format("%H:%M:%S")
        .to_string()
}

/// Strip control characters (incl. ESC) from event text: it embeds
/// client-supplied names and paths, and raw bytes must never reach a
/// terminal (plain-mode log lines) or the TUI.
fn sanitize(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).collect()
}

/// Record an event and print it as a plain log line (unless the TUI owns
/// the terminal).
pub fn emit_event(log: &ActivityLog, text: String) {
    let text = sanitize(&text);
    if PLAIN_MODE.load(Ordering::Relaxed) {
        eprintln!("[{}] {text}", fmt_stamp(SystemTime::now()));
    }
    log.add_event(text);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    #[test]
    fn online_within_ttl_then_expires() {
        let log = ActivityLog::with_ttl(Duration::from_secs(10));
        let ip = IpAddr::V4(Ipv4Addr::new(1, 2, 3, 4));
        log.touch(ip);
        let now = Instant::now();
        assert_eq!(log.online_at(now + Duration::from_secs(9)), vec![ip]);
        // a poll every 2s keeps the client visible; 10s after the last
        // request it is shown offline
        assert_eq!(log.online_at(now + Duration::from_secs(11)), Vec::<IpAddr>::new());
    }

    #[test]
    fn any_request_refreshes_presence() {
        let log = ActivityLog::with_ttl(Duration::from_secs(10));
        let ip = IpAddr::V4(Ipv4Addr::LOCALHOST);
        let now = Instant::now();
        log.last_seen.lock().unwrap().insert(ip, now - Duration::from_secs(8));
        log.touch(ip);
        assert_eq!(log.online_at(now + Duration::from_secs(9)), vec![ip]);
    }

    #[test]
    fn events_capped() {
        let log = ActivityLog {
            ttl: Duration::from_secs(10),
            max_events: 5,
            last_seen: Mutex::new(HashMap::new()),
            events: Mutex::new(VecDeque::new()),
        };
        for i in 0..10 {
            log.add_event(format!("e{i}"));
        }
        let events = log.events();
        let texts: Vec<&str> = events.iter().map(|(_, t)| t.as_str()).collect();
        assert_eq!(texts, ["e5", "e6", "e7", "e8", "e9"]);
    }

    #[test]
    fn emit_event_strips_control_chars() {
        // event text embeds client-supplied names and paths: raw control
        // bytes (terminal escape sequences) must never be stored or printed
        let log = ActivityLog::new();
        emit_event(&log, "x\u{1b}]52;c;oops\u{7} y\u{0}z".to_string());
        let events = log.events();
        assert_eq!(events.last().unwrap().1, "x]52;c;oops yz");
    }

    #[test]
    fn fmt_stamp_is_local_time_of_day() {
        // must format the wall clock, not UTC-offset epoch math
        let now = SystemTime::now();
        let stamp = fmt_stamp(now);
        assert_eq!(stamp.len(), 8, "HH:MM:SS, got {stamp}");
        assert!(stamp.chars().all(|c| c.is_ascii_digit() || c == ':'));
        let expected = chrono::DateTime::<chrono::Local>::from(now)
            .format("%H:%M:%S")
            .to_string();
        // tolerate a second boundary crossing between the two reads
        assert!(
            stamp == expected
                || stamp
                    == chrono::DateTime::<chrono::Local>::from(now + Duration::from_secs(1))
                        .format("%H:%M:%S")
                        .to_string(),
            "stamp={stamp} expected={expected}"
        );
    }
}
