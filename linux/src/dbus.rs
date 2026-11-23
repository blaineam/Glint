//! D-Bus pieces: built-in panel brightness through systemd-logind (unprivileged; the same
//! call desktops use for laptop and Steam Deck screens) and the on-screen indicator as a
//! desktop notification with a progress value (KDE, GNOME, XFCE, LXQt and most others).

use std::collections::HashMap;

use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, Value};

const LOGIN1: &str = "org.freedesktop.login1";

/// Sets a `/sys/class/backlight` device through the user's logind session.
pub struct Logind {
    conn: Connection,
    session: OwnedObjectPath,
}

impl Logind {
    pub fn connect() -> Option<Logind> {
        let conn = Connection::system().ok()?;
        let session = Self::session(&conn)?;
        Some(Logind { conn, session })
    }

    /// The user's seated (graphical) session. A systemd user service isn't inside the
    /// session itself, so "session/auto" doesn't work; list sessions and pick ours.
    fn session(conn: &Connection) -> Option<OwnedObjectPath> {
        // SAFETY: getuid has no preconditions.
        let uid = unsafe { libc::getuid() };
        let reply = conn
            .call_method(
                Some(LOGIN1),
                "/org/freedesktop/login1",
                Some("org.freedesktop.login1.Manager"),
                "ListSessions",
                &(),
            )
            .ok()?;
        let sessions: Vec<(String, u32, String, String, OwnedObjectPath)> = reply.body().deserialize().ok()?;
        let mine: Vec<_> = sessions.into_iter().filter(|s| s.1 == uid).collect();
        mine.iter().find(|s| !s.3.is_empty()).or(mine.first()).map(|s| s.4.clone())
    }

    pub fn set_brightness(&self, device: &str, value: u32) -> bool {
        self.conn
            .call_method(
                Some(LOGIN1),
                self.session.as_str(),
                Some("org.freedesktop.login1.Session"),
                "SetBrightness",
                &("backlight", device, value),
            )
            .is_ok()
    }
}

/// The level indicator, as a notification that replaces itself while keys are held.
pub struct Notifier {
    conn: Option<Connection>,
    last_id: u32,
}

impl Notifier {
    pub fn new() -> Notifier {
        Notifier { conn: Connection::session().ok(), last_id: 0 }
    }

    pub fn show(&mut self, summary: &str, icon: &str, percent: Option<f64>) {
        let Some(conn) = &self.conn else { return };
        let mut hints: HashMap<&str, Value> = HashMap::new();
        if let Some(p) = percent {
            hints.insert("value", Value::from(p.round() as i32));
        }
        // GNOME/Ubuntu: replace in place instead of stacking; KDE: don't keep in history.
        hints.insert("x-canonical-private-synchronous", Value::from("glint"));
        hints.insert("transient", Value::from(true));
        hints.insert("urgency", Value::from(0u8));
        let reply = conn.call_method(
            Some("org.freedesktop.Notifications"),
            "/org/freedesktop/Notifications",
            Some("org.freedesktop.Notifications"),
            "Notify",
            &("Glint", self.last_id, icon, summary, "", Vec::<&str>::new(), hints, 1500i32),
        );
        if let Ok(r) = reply {
            if let Ok(id) = r.body().deserialize::<u32>() {
                self.last_id = id;
            }
        }
    }

    /// A one-off message (not the level indicator).
    pub fn message(&self, summary: &str, body: &str) {
        let Some(conn) = &self.conn else { return };
        let hints: HashMap<&str, Value> = HashMap::new();
        let _ = conn.call_method(
            Some("org.freedesktop.Notifications"),
            "/org/freedesktop/Notifications",
            Some("org.freedesktop.Notifications"),
            "Notify",
            &("Glint", 0u32, "glint", summary, body, Vec::<&str>::new(), hints, 10_000i32),
        );
    }
}
