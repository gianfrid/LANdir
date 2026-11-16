//! Client activity tracking: presence (which IPs were seen within a TTL) and
//! an event log (uploads/downloads/errors with the client IP). The container
//! has no TTY, so this is plain line logs — listing polls are never logged,
//! they only refresh presence.

use std::collections::{HashMap, VecDeque};
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// How long a client stays "online" after its last request.
pub const PRESENCE_TTL: Duration = Duration::from_secs(10);

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
    let secs = t
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (h, m, s) = (secs / 3600 % 24, secs / 60 % 60, secs % 60);
    format!("{h:02}:{m:02}:{s:02}")
}

/// Record an event and print it as a log line.
pub fn emit_event(log: &ActivityLog, text: String) {
    eprintln!("[{}] {text}", fmt_stamp(SystemTime::now()));
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
}
