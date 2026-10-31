use std::fs;
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::thread;
use std::time::Duration;

use futures_util::StreamExt;
use thiserror::Error;
use zbus::fdo::RequestNameFlags;
use zbus::{Connection, OwnedObjectPath, Proxy};

const BUS_NAME: &str = "io.github.KercyDing.kocr";
const SERVICE: &str = "org.kde.kglobalaccel";
const SERVICE_PATH: &str = "/kglobalaccel";
const COMPONENT: &str = "kocr";
const COPY_ACTION: &str = "copy";
const OCR_ACTION: &str = "capture-ocr";
const ONELINE_ACTION: &str = "capture-ocr-oneline";
const POLL_INTERVAL: Duration = Duration::from_millis(500);
const SET_PRESENT_NO_AUTOLOAD: u32 = 2 | 4;

#[derive(Debug, Error)]
pub(crate) enum KeyboardError {
    #[error("{0}")]
    Operation(String),
}

enum Event {
    Trigger(Trigger),
    Reregister,
}

#[derive(Clone, Copy)]
enum Trigger {
    Copy,
    Ocr,
    Oneline,
}

impl Trigger {
    fn capture_options(self) -> (bool, bool) {
        match self {
            Self::Copy => (false, false),
            Self::Ocr => (true, false),
            Self::Oneline => (true, true),
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
struct Binding {
    name: String,
    key: i32,
}

#[derive(Clone, Default, PartialEq, Eq)]
struct Bindings {
    copy: Option<Binding>,
    ocr: Option<Binding>,
    oneline: Option<Binding>,
}

pub(crate) fn run<F, E>(mut on_trigger: F) -> Result<(), KeyboardError>
where
    F: FnMut(bool, bool) -> Result<(), E>,
    E: std::fmt::Display,
{
    let connection = zbus::block_on(Connection::session())
        .map_err(|error| operation("could not connect to the session bus", error))?;
    // zbus defaults to REPLACE_EXISTING, which would silently displace an
    // already-running daemon. Queuing is also undesirable for a singleton.
    zbus::block_on(connection.request_name_with_flags(BUS_NAME, RequestNameFlags::DO_NOT_QUEUE))
        .map_err(|error| operation("another daemon is already running", error))?;

    let mut bindings = load_bindings()?;
    register(&connection, &bindings)?;
    if kocr::models::selected_profile().is_err() {
        notify_no_model();
    }

    let (events_tx, events_rx) = mpsc::sync_channel(8);
    let trigger_pending = Arc::new(AtomicBool::new(false));
    spawn_listener(connection.clone(), events_tx, Arc::clone(&trigger_pending));

    let mut config_content = read_config_content();
    eprintln!("Shortcut daemon started");
    loop {
        match events_rx.recv_timeout(POLL_INTERVAL) {
            Ok(Event::Trigger(trigger)) => {
                if kocr::models::selected_profile().is_err() {
                    notify_no_model();
                } else if let Err(error) = on_trigger_options(&mut on_trigger, trigger) {
                    eprintln!("\x1b[31mShortcut capture failed: {error}\x1b[0m");
                }
                trigger_pending.store(false, Ordering::Release);
            }
            Ok(Event::Reregister) => {
                if let Err(error) = register(&connection, &bindings) {
                    eprintln!("\x1b[31mShortcut registration failed: {error}\x1b[0m");
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err(KeyboardError::Operation(
                    "shortcut listener stopped unexpectedly".to_owned(),
                ));
            }
        }
        reload_config(&connection, &mut config_content, &mut bindings);
    }
}

fn on_trigger_options<F, E>(on_trigger: &mut F, trigger: Trigger) -> Result<(), E>
where
    F: FnMut(bool, bool) -> Result<(), E>,
{
    let (recognize, oneline) = trigger.capture_options();
    on_trigger(recognize, oneline)
}

fn reload_config(
    connection: &Connection,
    previous_content: &mut Option<String>,
    current_bindings: &mut Bindings,
) {
    let content = read_config_content();
    if content == *previous_content {
        return;
    }
    *previous_content = content;

    let bindings = match load_bindings() {
        Ok(bindings) => bindings,
        Err(error) => {
            eprintln!("\x1b[31mShortcut reload failed: {error}\x1b[0m");
            return;
        }
    };
    if bindings == *current_bindings {
        return;
    }
    match register(connection, &bindings) {
        Ok(()) => {
            *current_bindings = bindings;
            eprintln!("Shortcuts reloaded");
        }
        Err(error) => {
            eprintln!("\x1b[31mShortcut reload failed: {error}\x1b[0m");
            let _ = register(connection, current_bindings);
        }
    }
}

fn spawn_listener(
    connection: Connection,
    events: SyncSender<Event>,
    trigger_pending: Arc<AtomicBool>,
) {
    thread::spawn(move || {
        loop {
            if let Err(error) = zbus::block_on(listen(&connection, &events, &trigger_pending)) {
                eprintln!("\x1b[31mShortcut listener failed: {error}\x1b[0m");
            }
            thread::sleep(POLL_INTERVAL);
            let _ = events.try_send(Event::Reregister);
        }
    });
}

async fn listen(
    connection: &Connection,
    events: &SyncSender<Event>,
    trigger_pending: &AtomicBool,
) -> Result<(), KeyboardError> {
    let component = component_proxy(connection).await?;
    let mut signals = component
        .receive_signal("globalShortcutPressed")
        .await
        .map_err(|error| operation("could not subscribe to shortcut events", error))?;
    while let Some(message) = signals.next().await {
        let body = message.body();
        let Ok((component, action, _timestamp)) = body.deserialize::<(String, String, i64)>()
        else {
            continue;
        };
        let trigger = match action.as_str() {
            COPY_ACTION => Trigger::Copy,
            OCR_ACTION => Trigger::Ocr,
            ONELINE_ACTION => Trigger::Oneline,
            _ => continue,
        };
        if component == COMPONENT
            && !trigger_pending.swap(true, Ordering::AcqRel)
            && events.try_send(Event::Trigger(trigger)).is_err()
        {
            trigger_pending.store(false, Ordering::Release);
        }
    }
    Ok(())
}

fn register(connection: &Connection, bindings: &Bindings) -> Result<(), KeyboardError> {
    zbus::block_on(register_async(connection, bindings))
}

async fn register_async(connection: &Connection, bindings: &Bindings) -> Result<(), KeyboardError> {
    let proxy = service_proxy(connection).await?;
    register_action(
        &proxy,
        COPY_ACTION,
        "Capture and copy screenshot",
        bindings.copy.as_ref(),
    )
    .await?;
    register_action(
        &proxy,
        OCR_ACTION,
        "Capture screenshot and recognize text",
        bindings.ocr.as_ref(),
    )
    .await?;
    register_action(
        &proxy,
        ONELINE_ACTION,
        "Capture screenshot and recognize text in one line",
        bindings.oneline.as_ref(),
    )
    .await
}

async fn register_action(
    proxy: &Proxy<'static>,
    action_name: &str,
    description: &str,
    binding: Option<&Binding>,
) -> Result<(), KeyboardError> {
    let action = action_id(action_name, description);
    let _: () = proxy
        .call("doRegister", &(action.clone(),))
        .await
        .map_err(|error| operation("could not register shortcut action", error))?;
    let keys = binding
        .map(|binding| vec![(vec![binding.key, 0, 0, 0],)])
        .unwrap_or_default();
    let assigned: Vec<(Vec<i32>,)> = proxy
        .call("setShortcutKeys", &(action, keys, SET_PRESENT_NO_AUTOLOAD))
        .await
        .map_err(|error| operation("could not set global shortcut", error))?;
    if let Some(binding) = binding
        && !assigned.iter().any(|(keys,)| keys.contains(&binding.key))
    {
        return Err(KeyboardError::Operation(format!(
            "shortcut is unavailable: {}",
            binding.name
        )));
    }
    Ok(())
}

async fn service_proxy(connection: &Connection) -> Result<Proxy<'static>, KeyboardError> {
    Proxy::new(connection, SERVICE, SERVICE_PATH, "org.kde.KGlobalAccel")
        .await
        .map_err(|error| operation("could not connect to KGlobalAccel", error))
}

async fn component_proxy(connection: &Connection) -> Result<Proxy<'static>, KeyboardError> {
    let path: OwnedObjectPath = service_proxy(connection)
        .await?
        .call("getComponent", &(COMPONENT,))
        .await
        .map_err(|error| operation("could not find shortcut component", error))?;
    Proxy::new(connection, SERVICE, path, "org.kde.kglobalaccel.Component")
        .await
        .map_err(|error| operation("could not connect to shortcut component", error))
}

fn action_id(action: &str, description: &str) -> Vec<String> {
    [COMPONENT, action, "KOCR", description]
        .map(str::to_owned)
        .to_vec()
}

fn load_bindings() -> Result<Bindings, KeyboardError> {
    let shortcuts = kocr::models::shortcuts().map_err(|error| {
        KeyboardError::Operation(format!("could not load shortcut configuration: {error}"))
    })?;
    let copy = parse_binding(shortcuts.copy)?;
    let ocr = parse_binding(shortcuts.ocr)?;
    let oneline = parse_binding(shortcuts.oneline)?;
    Ok(Bindings { copy, ocr, oneline })
}

fn parse_binding(shortcut: Option<String>) -> Result<Option<Binding>, KeyboardError> {
    shortcut
        .map(|name| {
            let key = kocr_config::parse_shortcut(&name)
                .map_err(|error| KeyboardError::Operation(error.to_string()))?;
            Ok(Binding { name, key })
        })
        .transpose()
}

fn read_config_content() -> Option<String> {
    fs::read_to_string(kocr_config::config_path()).ok()
}

fn notify_no_model() {
    const TITLE: &str = "KOCR";
    const BODY: &str = "No OCR model available. Install one with kocr install 1.";

    eprintln!("\x1b[31m{BODY}\x1b[0m");
    match Command::new("notify-send")
        .args(["--app-name", TITLE, TITLE, BODY])
        .status()
    {
        Ok(status) if status.success() => {}
        Ok(status) => eprintln!("\x1b[31mCould not show notification: {status}\x1b[0m"),
        Err(error) => eprintln!("\x1b[31mCould not show notification: {error}\x1b[0m"),
    }
}

fn operation(context: &str, error: impl std::fmt::Display) -> KeyboardError {
    KeyboardError::Operation(format!("{context}: {error}"))
}

#[cfg(test)]
mod tests {
    use super::{Trigger, parse_binding};

    #[test]
    fn accepts_disabled_binding() {
        assert!(parse_binding(None).unwrap().is_none());
    }

    #[test]
    fn maps_capture_options() {
        assert_eq!(Trigger::Copy.capture_options(), (false, false));
        assert_eq!(Trigger::Ocr.capture_options(), (true, false));
        assert_eq!(Trigger::Oneline.capture_options(), (true, true));
    }
}
