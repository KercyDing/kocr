use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::thread;

use futures_util::StreamExt;
use kocr_config::{Key, Modifiers, Shortcut};
use zbus::fdo::RequestNameFlags;
use zbus::{Connection, OwnedObjectPath, Proxy};

use super::{
    Configured, KeyboardError, POLL_INTERVAL, Trigger, notify_no_model, on_trigger_options,
    operation, read_config_content,
};

const BUS_NAME: &str = "io.github.KercyDing.kocr";
const SERVICE: &str = "org.kde.kglobalaccel";
const SERVICE_PATH: &str = "/kglobalaccel";
const COMPONENT: &str = "kocr";
const COPY_ACTION: &str = "copy";
const OCR_ACTION: &str = "capture-ocr";
const ONELINE_ACTION: &str = "capture-ocr-oneline";
const SET_PRESENT_NO_AUTOLOAD: u32 = 2 | 4;

const QT_SHIFT: i32 = 0x0200_0000;
const QT_CONTROL: i32 = 0x0400_0000;
const QT_ALT: i32 = 0x0800_0000;
const QT_META: i32 = 0x1000_0000;

enum Event {
    Trigger(Trigger),
    Reregister,
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

impl Bindings {
    fn from_configured(configured: Configured) -> Self {
        Self {
            copy: configured.copy.map(binding),
            ocr: configured.ocr.map(binding),
            oneline: configured.oneline.map(binding),
        }
    }
}

fn binding((name, shortcut): (String, Shortcut)) -> Binding {
    Binding {
        name,
        key: qt_key(shortcut),
    }
}

pub(super) fn run<F, E>(mut on_trigger: F) -> Result<(), KeyboardError>
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

    let mut bindings = Bindings::from_configured(Configured::load()?);
    register(&connection, &bindings)?;
    if kocr_core::models::selected_profile().is_err() {
        notify_no_model();
    }

    let (events_tx, events_rx) = mpsc::sync_channel(8);
    let trigger_pending = Arc::new(AtomicBool::new(false));
    spawn_listener(connection.clone(), events_tx, Arc::clone(&trigger_pending));

    let mut config_content = read_config_content();
    eprintln!("Shortcut daemon started (Wayland)");
    loop {
        match events_rx.recv_timeout(POLL_INTERVAL) {
            Ok(Event::Trigger(trigger)) => {
                if kocr_core::models::selected_profile().is_err() {
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

    let bindings = match Configured::load() {
        Ok(configured) => Bindings::from_configured(configured),
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

fn qt_key(shortcut: Shortcut) -> i32 {
    let mut modifiers = 0;
    if shortcut.modifiers.contains(Modifiers::SUPER) {
        modifiers |= QT_META;
    }
    if shortcut.modifiers.contains(Modifiers::CONTROL) {
        modifiers |= QT_CONTROL;
    }
    if shortcut.modifiers.contains(Modifiers::ALT) {
        modifiers |= QT_ALT;
    }
    if shortcut.modifiers.contains(Modifiers::SHIFT) {
        modifiers |= QT_SHIFT;
    }
    modifiers | qt_key_code(shortcut.key)
}

fn qt_key_code(key: Key) -> i32 {
    match key {
        Key::Character(character) => character as i32,
        Key::Function(number) => 0x0100_0030 + i32::from(number) - 1,
        Key::Escape => 0x0100_0000,
        Key::Tab => 0x0100_0001,
        Key::Backspace => 0x0100_0003,
        Key::Return => 0x0100_0004,
        Key::Enter => 0x0100_0005,
        Key::Insert => 0x0100_0006,
        Key::Delete => 0x0100_0007,
        Key::Pause => 0x0100_0008,
        Key::Print => 0x0100_0009,
        Key::Home => 0x0100_0010,
        Key::End => 0x0100_0011,
        Key::Left => 0x0100_0012,
        Key::Up => 0x0100_0013,
        Key::Right => 0x0100_0014,
        Key::Down => 0x0100_0015,
        Key::PageUp => 0x0100_0016,
        Key::PageDown => 0x0100_0017,
        Key::Space => 0x20,
        Key::Apostrophe => '\'' as i32,
        Key::Comma => ',' as i32,
        Key::Minus => '-' as i32,
        Key::Period => '.' as i32,
        Key::Slash => '/' as i32,
        Key::Semicolon => ';' as i32,
        Key::Equal => '=' as i32,
        Key::BracketLeft => '[' as i32,
        Key::Backslash => '\\' as i32,
        Key::BracketRight => ']' as i32,
        Key::Grave => '`' as i32,
        Key::AudioLowerVolume => 0x0100_0070,
        Key::AudioMute => 0x0100_0071,
        Key::AudioRaiseVolume => 0x0100_0072,
        Key::AudioPlay => 0x0100_0080,
        Key::AudioStop => 0x0100_0081,
        Key::AudioPrev => 0x0100_0082,
        Key::AudioNext => 0x0100_0083,
        Key::AudioPause => 0x0100_0085,
        Key::BrightnessUp => 0x0100_00b2,
        Key::BrightnessDown => 0x0100_00b3,
    }
}

#[cfg(test)]
mod tests {
    use super::{QT_ALT, QT_META, QT_SHIFT, qt_key};
    use kocr_config::parse_shortcut;

    #[test]
    fn encodes_qt_shortcuts() {
        assert_eq!(
            qt_key(parse_shortcut("Alt+1").unwrap()),
            QT_ALT | '1' as i32
        );
        assert_eq!(
            qt_key(parse_shortcut("Mod+Shift+Slash").unwrap()),
            QT_META | QT_SHIFT | '/' as i32
        );
    }
}
