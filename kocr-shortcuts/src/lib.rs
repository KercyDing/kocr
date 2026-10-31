use std::fmt::Display;

use thiserror::Error;

#[cfg(target_os = "linux")]
use std::fs;
#[cfg(target_os = "linux")]
use std::time::Duration;

#[cfg(target_os = "linux")]
use kocr_config::Shortcut;

#[cfg(target_os = "linux")]
mod global;
#[cfg(target_os = "linux")]
mod kglobalaccel;

#[cfg(target_os = "linux")]
pub(crate) const POLL_INTERVAL: Duration = Duration::from_millis(500);

#[derive(Debug, Error)]
pub enum KeyboardError {
    #[error("{0}")]
    Operation(String),
}

#[cfg(target_os = "linux")]
pub(crate) fn operation(context: &str, error: impl Display) -> KeyboardError {
    KeyboardError::Operation(format!("{context}: {error}"))
}

#[cfg(target_os = "linux")]
#[derive(Clone, Copy)]
pub(crate) enum Trigger {
    Copy,
    Ocr,
    Oneline,
}

#[cfg(target_os = "linux")]
impl Trigger {
    pub(crate) fn capture_options(self) -> (bool, bool) {
        match self {
            Self::Copy => (false, false),
            Self::Ocr => (true, false),
            Self::Oneline => (true, true),
        }
    }
}

#[cfg(target_os = "linux")]
pub(crate) fn on_trigger_options<F, E>(on_trigger: &mut F, trigger: Trigger) -> Result<(), E>
where
    F: FnMut(bool, bool) -> Result<(), E>,
{
    let (recognize, oneline) = trigger.capture_options();
    on_trigger(recognize, oneline)
}

/// Shortcut configuration parsed into backend-neutral values.
#[cfg(target_os = "linux")]
pub(crate) struct Configured {
    pub(crate) copy: Option<(String, Shortcut)>,
    pub(crate) ocr: Option<(String, Shortcut)>,
    pub(crate) oneline: Option<(String, Shortcut)>,
}

#[cfg(target_os = "linux")]
impl Configured {
    pub(crate) fn load() -> Result<Self, KeyboardError> {
        let shortcuts = kocr_core::models::shortcuts().map_err(|error| {
            KeyboardError::Operation(format!("could not load shortcut configuration: {error}"))
        })?;
        Ok(Self {
            copy: parse_binding(shortcuts.copy)?,
            ocr: parse_binding(shortcuts.ocr)?,
            oneline: parse_binding(shortcuts.oneline)?,
        })
    }
}

#[cfg(target_os = "linux")]
fn parse_binding(shortcut: Option<String>) -> Result<Option<(String, Shortcut)>, KeyboardError> {
    shortcut
        .map(|name| {
            let shortcut = kocr_config::parse_shortcut(&name)
                .map_err(|error| KeyboardError::Operation(error.to_string()))?;
            Ok((name, shortcut))
        })
        .transpose()
}

#[cfg(target_os = "linux")]
pub(crate) fn read_config_content() -> Option<String> {
    fs::read_to_string(kocr_config::config_path()).ok()
}

#[cfg(target_os = "linux")]
pub(crate) fn notify_no_model() {
    const TITLE: &str = "KOCR";
    const BODY: &str = "No OCR model available. Install one with kocr install 1.";

    eprintln!("\x1b[31m{BODY}\x1b[0m");
    match std::process::Command::new("notify-send")
        .args(["--app-name", TITLE, TITLE, BODY])
        .status()
    {
        Ok(status) if status.success() => {}
        Ok(status) => eprintln!("\x1b[31mCould not show notification: {status}\x1b[0m"),
        Err(error) => eprintln!("\x1b[31mCould not show notification: {error}\x1b[0m"),
    }
}

/// Global shortcuts on Linux come from two backends: KGlobalAccel on Wayland
/// and global-hotkey on X11. Other platforms are not implemented yet.
pub fn run<F, E>(on_trigger: F) -> Result<(), KeyboardError>
where
    F: FnMut(bool, bool) -> Result<(), E>,
    E: Display,
{
    #[cfg(target_os = "linux")]
    {
        match session() {
            Session::Wayland => kglobalaccel::run(on_trigger),
            Session::X11 | Session::Other => global::run(on_trigger),
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = on_trigger;
        Err(KeyboardError::Operation(
            "global shortcuts are not implemented for this platform yet".to_owned(),
        ))
    }
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Session {
    Wayland,
    X11,
    Other,
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn session() -> Session {
    session_from(
        std::env::var("XDG_SESSION_TYPE").ok().as_deref(),
        std::env::var("WAYLAND_DISPLAY").ok().as_deref(),
        std::env::var("DISPLAY").ok().as_deref(),
    )
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn session_from(
    xdg_session_type: Option<&str>,
    wayland_display: Option<&str>,
    display: Option<&str>,
) -> Session {
    let wayland = match xdg_session_type.filter(|value| !value.is_empty()) {
        Some(session) => session.eq_ignore_ascii_case("wayland"),
        None => wayland_display.is_some_and(|value| !value.is_empty()),
    };
    if wayland {
        Session::Wayland
    } else if display.is_some_and(|value| !value.is_empty()) {
        Session::X11
    } else {
        Session::Other
    }
}

#[cfg(test)]
mod tests {
    use super::{Session, session_from};
    #[cfg(target_os = "linux")]
    use super::{Trigger, parse_binding};

    #[cfg(target_os = "linux")]
    #[test]
    fn accepts_disabled_binding() {
        assert!(parse_binding(None).unwrap().is_none());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn maps_capture_options() {
        assert_eq!(Trigger::Copy.capture_options(), (false, false));
        assert_eq!(Trigger::Ocr.capture_options(), (true, false));
        assert_eq!(Trigger::Oneline.capture_options(), (true, true));
    }

    #[test]
    fn detects_wayland() {
        assert_eq!(
            session_from(Some("wayland"), None, Some(":0")),
            Session::Wayland
        );
        assert_eq!(
            session_from(None, Some("wayland-0"), Some(":0")),
            Session::Wayland
        );
    }

    #[test]
    fn detects_x11() {
        assert_eq!(session_from(Some("x11"), None, Some(":0")), Session::X11);
    }

    #[test]
    fn detects_other() {
        assert_eq!(session_from(None, None, None), Session::Other);
    }
}
