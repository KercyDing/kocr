use std::fmt::Display;

use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};
use kocr_config::{Key, Modifiers as ConfigModifiers, Shortcut};

use super::{
    Configured, KeyboardError, POLL_INTERVAL, Trigger, notify_no_model, on_trigger_options,
    operation, read_config_content,
};

#[derive(Clone, PartialEq, Eq)]
struct Binding {
    name: String,
    hotkey: HotKey,
}

impl Binding {
    fn new((name, shortcut): (String, Shortcut)) -> Self {
        Self {
            name,
            hotkey: hotkey(shortcut),
        }
    }
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
            copy: configured.copy.map(Binding::new),
            ocr: configured.ocr.map(Binding::new),
            oneline: configured.oneline.map(Binding::new),
        }
    }

    fn trigger(&self, id: u32) -> Option<Trigger> {
        [
            (&self.copy, Trigger::Copy),
            (&self.ocr, Trigger::Ocr),
            (&self.oneline, Trigger::Oneline),
        ]
        .into_iter()
        .find(|(binding, _)| {
            binding
                .as_ref()
                .is_some_and(|binding| binding.hotkey.id() == id)
        })
        .map(|(_, trigger)| trigger)
    }
}

pub(super) fn run<F, E>(mut on_trigger: F) -> Result<(), KeyboardError>
where
    F: FnMut(bool, bool) -> Result<(), E>,
    E: Display,
{
    // Creating the manager also connects to the X server. On a Wayland
    // session without XWayland this fails, which the caller avoids by
    // selecting the KGlobalAccel backend instead.
    let manager = GlobalHotKeyManager::new().map_err(|error| {
        operation(
            "could not create the X11 hotkey manager (an X11 session is required)",
            error,
        )
    })?;

    let mut bindings = Bindings::from_configured(Configured::load()?);
    register(&manager, &bindings)?;
    if kocr_core::models::selected_profile().is_err() {
        notify_no_model();
    }

    let mut config_content = read_config_content();
    #[cfg(target_os = "linux")]
    eprintln!("KOCR shortcuts started (X11)");
    #[cfg(target_os = "macos")]
    eprintln!("KOCR shortcuts started (macOS)");
    #[cfg(windows)]
    eprintln!("KOCR shortcuts started (Windows)");
    loop {
        if let Ok(event) = GlobalHotKeyEvent::receiver().recv_timeout(POLL_INTERVAL)
            && event.state() == HotKeyState::Pressed
            && let Some(trigger) = bindings.trigger(event.id())
        {
            if kocr_core::models::selected_profile().is_err() {
                notify_no_model();
            } else if let Err(error) = on_trigger_options(&mut on_trigger, trigger) {
                eprintln!("\x1b[31mShortcut capture failed: {error}\x1b[0m");
            }
        }
        reload_config(&manager, &mut config_content, &mut bindings);
    }
}

fn register(manager: &GlobalHotKeyManager, bindings: &Bindings) -> Result<(), KeyboardError> {
    register_binding(manager, bindings.copy.as_ref())?;
    register_binding(manager, bindings.ocr.as_ref())?;
    register_binding(manager, bindings.oneline.as_ref())
}

fn register_binding(
    manager: &GlobalHotKeyManager,
    binding: Option<&Binding>,
) -> Result<(), KeyboardError> {
    let Some(binding) = binding else {
        return Ok(());
    };
    manager.register(binding.hotkey).map_err(|error| {
        operation(
            &format!("could not register shortcut {}", binding.name),
            error,
        )
    })
}

fn unregister(manager: &GlobalHotKeyManager, bindings: &Bindings) {
    unregister_binding(manager, bindings.copy.as_ref());
    unregister_binding(manager, bindings.ocr.as_ref());
    unregister_binding(manager, bindings.oneline.as_ref());
}

fn unregister_binding(manager: &GlobalHotKeyManager, binding: Option<&Binding>) {
    if let Some(binding) = binding {
        let _ = manager.unregister(binding.hotkey);
    }
}

fn reload_config(
    manager: &GlobalHotKeyManager,
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
    unregister(manager, current_bindings);
    match register(manager, &bindings) {
        Ok(()) => {
            *current_bindings = bindings;
            eprintln!("Shortcuts reloaded");
        }
        Err(error) => {
            eprintln!("\x1b[31mShortcut reload failed: {error}\x1b[0m");
            unregister(manager, &bindings);
            if let Err(error) = register(manager, current_bindings) {
                eprintln!("\x1b[31mShortcut restore failed: {error}\x1b[0m");
            }
        }
    }
}

fn hotkey(shortcut: Shortcut) -> HotKey {
    let mut modifiers = Modifiers::empty();
    if shortcut.modifiers.contains(ConfigModifiers::SUPER) {
        modifiers |= Modifiers::META;
    }
    if shortcut.modifiers.contains(ConfigModifiers::CONTROL) {
        modifiers |= Modifiers::CONTROL;
    }
    if shortcut.modifiers.contains(ConfigModifiers::ALT) {
        modifiers |= Modifiers::ALT;
    }
    if shortcut.modifiers.contains(ConfigModifiers::SHIFT) {
        modifiers |= Modifiers::SHIFT;
    }
    HotKey::new(
        (!modifiers.is_empty()).then_some(modifiers),
        code(shortcut.key),
    )
}

fn code(key: Key) -> Code {
    match key {
        Key::Character(character) => character_code(character),
        Key::Function(number) => function_code(number),
        Key::Escape => Code::Escape,
        Key::Tab => Code::Tab,
        Key::Backspace => Code::Backspace,
        Key::Return => Code::Enter,
        Key::Enter => Code::NumpadEnter,
        Key::Insert => Code::Insert,
        Key::Delete => Code::Delete,
        Key::Pause => Code::Pause,
        Key::Print => Code::PrintScreen,
        Key::Home => Code::Home,
        Key::End => Code::End,
        Key::Left => Code::ArrowLeft,
        Key::Up => Code::ArrowUp,
        Key::Right => Code::ArrowRight,
        Key::Down => Code::ArrowDown,
        Key::PageUp => Code::PageUp,
        Key::PageDown => Code::PageDown,
        Key::Space => Code::Space,
        Key::Apostrophe => Code::Quote,
        Key::Comma => Code::Comma,
        Key::Minus => Code::Minus,
        Key::Period => Code::Period,
        Key::Slash => Code::Slash,
        Key::Semicolon => Code::Semicolon,
        Key::Equal => Code::Equal,
        Key::BracketLeft => Code::BracketLeft,
        Key::Backslash => Code::Backslash,
        Key::BracketRight => Code::BracketRight,
        Key::Grave => Code::Backquote,
        Key::AudioLowerVolume => Code::AudioVolumeDown,
        Key::AudioMute => Code::AudioVolumeMute,
        Key::AudioRaiseVolume => Code::AudioVolumeUp,
        Key::AudioPlay => Code::MediaPlay,
        Key::AudioStop => Code::MediaStop,
        Key::AudioPrev => Code::MediaTrackPrevious,
        Key::AudioNext => Code::MediaTrackNext,
        Key::AudioPause => Code::MediaPause,
        Key::BrightnessUp => Code::BrightnessUp,
        Key::BrightnessDown => Code::BrightnessDown,
    }
}

fn character_code(character: char) -> Code {
    match character {
        'A' => Code::KeyA,
        'B' => Code::KeyB,
        'C' => Code::KeyC,
        'D' => Code::KeyD,
        'E' => Code::KeyE,
        'F' => Code::KeyF,
        'G' => Code::KeyG,
        'H' => Code::KeyH,
        'I' => Code::KeyI,
        'J' => Code::KeyJ,
        'K' => Code::KeyK,
        'L' => Code::KeyL,
        'M' => Code::KeyM,
        'N' => Code::KeyN,
        'O' => Code::KeyO,
        'P' => Code::KeyP,
        'Q' => Code::KeyQ,
        'R' => Code::KeyR,
        'S' => Code::KeyS,
        'T' => Code::KeyT,
        'U' => Code::KeyU,
        'V' => Code::KeyV,
        'W' => Code::KeyW,
        'X' => Code::KeyX,
        'Y' => Code::KeyY,
        'Z' => Code::KeyZ,
        '0' => Code::Digit0,
        '1' => Code::Digit1,
        '2' => Code::Digit2,
        '3' => Code::Digit3,
        '4' => Code::Digit4,
        '5' => Code::Digit5,
        '6' => Code::Digit6,
        '7' => Code::Digit7,
        '8' => Code::Digit8,
        '9' => Code::Digit9,
        _ => Code::Unidentified,
    }
}

fn function_code(number: u8) -> Code {
    match number {
        1 => Code::F1,
        2 => Code::F2,
        3 => Code::F3,
        4 => Code::F4,
        5 => Code::F5,
        6 => Code::F6,
        7 => Code::F7,
        8 => Code::F8,
        9 => Code::F9,
        10 => Code::F10,
        11 => Code::F11,
        12 => Code::F12,
        13 => Code::F13,
        14 => Code::F14,
        15 => Code::F15,
        16 => Code::F16,
        17 => Code::F17,
        18 => Code::F18,
        19 => Code::F19,
        20 => Code::F20,
        21 => Code::F21,
        22 => Code::F22,
        23 => Code::F23,
        24 => Code::F24,
        25 => Code::F25,
        26 => Code::F26,
        27 => Code::F27,
        28 => Code::F28,
        29 => Code::F29,
        30 => Code::F30,
        31 => Code::F31,
        32 => Code::F32,
        33 => Code::F33,
        34 => Code::F34,
        35 => Code::F35,
        _ => Code::Unidentified,
    }
}
