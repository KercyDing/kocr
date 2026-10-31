//! Shortcut input mapping and display.

use eframe::egui;
use kocr_config::{Key, Modifiers as ConfigModifiers, parse_shortcut};

pub(crate) fn shortcut_from_key(key: egui::Key, modifiers: egui::Modifiers) -> Option<String> {
    let key = config_key_name(key)?;
    let command = cfg!(target_os = "macos") && modifiers.mac_cmd;
    if !command && !modifiers.ctrl && !modifiers.alt {
        return None;
    }
    let mut parts = Vec::new();
    if command {
        parts.push("Super".to_owned());
    }
    if modifiers.ctrl {
        parts.push("Ctrl".to_owned());
    }
    if modifiers.alt {
        parts.push("Alt".to_owned());
    }
    if modifiers.shift {
        parts.push("Shift".to_owned());
    }
    parts.push(key);
    Some(parts.join("+"))
}

pub(crate) fn config_key_name(key: egui::Key) -> Option<String> {
    Some(
        match key {
            egui::Key::A => "A",
            egui::Key::B => "B",
            egui::Key::C => "C",
            egui::Key::D => "D",
            egui::Key::E => "E",
            egui::Key::F => "F",
            egui::Key::G => "G",
            egui::Key::H => "H",
            egui::Key::I => "I",
            egui::Key::J => "J",
            egui::Key::K => "K",
            egui::Key::L => "L",
            egui::Key::M => "M",
            egui::Key::N => "N",
            egui::Key::O => "O",
            egui::Key::P => "P",
            egui::Key::Q => "Q",
            egui::Key::R => "R",
            egui::Key::S => "S",
            egui::Key::T => "T",
            egui::Key::U => "U",
            egui::Key::V => "V",
            egui::Key::W => "W",
            egui::Key::X => "X",
            egui::Key::Y => "Y",
            egui::Key::Z => "Z",
            egui::Key::Num0 => "0",
            egui::Key::Num1 => "1",
            egui::Key::Num2 => "2",
            egui::Key::Num3 => "3",
            egui::Key::Num4 => "4",
            egui::Key::Num5 => "5",
            egui::Key::Num6 => "6",
            egui::Key::Num7 => "7",
            egui::Key::Num8 => "8",
            egui::Key::Num9 => "9",
            egui::Key::F1 => "F1",
            egui::Key::F2 => "F2",
            egui::Key::F3 => "F3",
            egui::Key::F4 => "F4",
            egui::Key::F5 => "F5",
            egui::Key::F6 => "F6",
            egui::Key::F7 => "F7",
            egui::Key::F8 => "F8",
            egui::Key::F9 => "F9",
            egui::Key::F10 => "F10",
            egui::Key::F11 => "F11",
            egui::Key::F12 => "F12",
            egui::Key::F13 => "F13",
            egui::Key::F14 => "F14",
            egui::Key::F15 => "F15",
            egui::Key::F16 => "F16",
            egui::Key::F17 => "F17",
            egui::Key::F18 => "F18",
            egui::Key::F19 => "F19",
            egui::Key::F20 => "F20",
            egui::Key::F21 => "F21",
            egui::Key::F22 => "F22",
            egui::Key::F23 => "F23",
            egui::Key::F24 => "F24",
            egui::Key::F25 => "F25",
            egui::Key::F26 => "F26",
            egui::Key::F27 => "F27",
            egui::Key::F28 => "F28",
            egui::Key::F29 => "F29",
            egui::Key::F30 => "F30",
            egui::Key::F31 => "F31",
            egui::Key::F32 => "F32",
            egui::Key::F33 => "F33",
            egui::Key::F34 => "F34",
            egui::Key::F35 => "F35",
            egui::Key::Escape => "Escape",
            egui::Key::Tab => "Tab",
            egui::Key::Backspace => "Backspace",
            egui::Key::Enter => "Return",
            egui::Key::Space => "Space",
            egui::Key::Insert => "Insert",
            egui::Key::Delete => "Delete",
            egui::Key::Home => "Home",
            egui::Key::End => "End",
            egui::Key::PageUp => "PageUp",
            egui::Key::PageDown => "PageDown",
            egui::Key::ArrowLeft => "Left",
            egui::Key::ArrowUp => "Up",
            egui::Key::ArrowRight => "Right",
            egui::Key::ArrowDown => "Down",
            egui::Key::Comma => "Comma",
            egui::Key::Backslash => "Backslash",
            egui::Key::Slash => "Slash",
            egui::Key::Minus => "Minus",
            egui::Key::Period => "Period",
            egui::Key::Semicolon => "Semicolon",
            egui::Key::Quote => "Apostrophe",
            egui::Key::Equals => "Equal",
            egui::Key::OpenBracket => "BracketLeft",
            egui::Key::CloseBracket => "BracketRight",
            egui::Key::Backtick => "Grave",
            _ => return None,
        }
        .to_owned(),
    )
}

pub(crate) fn format_shortcut(value: &str) -> String {
    let Ok(shortcut) = parse_shortcut(value.trim()) else {
        return if value.trim().is_empty() {
            t!("not_set").to_string()
        } else {
            value.to_owned()
        };
    };
    let mac = cfg!(target_os = "macos");
    let mut parts = Vec::new();
    if shortcut.modifiers.contains(ConfigModifiers::SUPER) {
        parts.push(if mac { "Cmd" } else { "Super" });
    }
    if shortcut.modifiers.contains(ConfigModifiers::CONTROL) {
        parts.push("Ctrl");
    }
    if shortcut.modifiers.contains(ConfigModifiers::ALT) {
        parts.push(if mac { "Opt" } else { "Alt" });
    }
    if shortcut.modifiers.contains(ConfigModifiers::SHIFT) {
        parts.push("Shift");
    }
    parts.push(display_key(shortcut.key));
    parts.join("+")
}

fn display_key(key: Key) -> &'static str {
    match key {
        Key::Character('0') => "0",
        Key::Character('1') => "1",
        Key::Character('2') => "2",
        Key::Character('3') => "3",
        Key::Character('4') => "4",
        Key::Character('5') => "5",
        Key::Character('6') => "6",
        Key::Character('7') => "7",
        Key::Character('8') => "8",
        Key::Character('9') => "9",
        Key::Character('A') => "A",
        Key::Character('B') => "B",
        Key::Character('C') => "C",
        Key::Character('D') => "D",
        Key::Character('E') => "E",
        Key::Character('F') => "F",
        Key::Character('G') => "G",
        Key::Character('H') => "H",
        Key::Character('I') => "I",
        Key::Character('J') => "J",
        Key::Character('K') => "K",
        Key::Character('L') => "L",
        Key::Character('M') => "M",
        Key::Character('N') => "N",
        Key::Character('O') => "O",
        Key::Character('P') => "P",
        Key::Character('Q') => "Q",
        Key::Character('R') => "R",
        Key::Character('S') => "S",
        Key::Character('T') => "T",
        Key::Character('U') => "U",
        Key::Character('V') => "V",
        Key::Character('W') => "W",
        Key::Character('X') => "X",
        Key::Character('Y') => "Y",
        Key::Character('Z') => "Z",
        Key::Function(1) => "F1",
        Key::Function(2) => "F2",
        Key::Function(3) => "F3",
        Key::Function(4) => "F4",
        Key::Function(5) => "F5",
        Key::Function(6) => "F6",
        Key::Function(7) => "F7",
        Key::Function(8) => "F8",
        Key::Function(9) => "F9",
        Key::Function(10) => "F10",
        Key::Function(11) => "F11",
        Key::Function(12) => "F12",
        Key::Function(13) => "F13",
        Key::Function(14) => "F14",
        Key::Function(15) => "F15",
        Key::Function(16) => "F16",
        Key::Function(17) => "F17",
        Key::Function(18) => "F18",
        Key::Function(19) => "F19",
        Key::Function(20) => "F20",
        Key::Function(21) => "F21",
        Key::Function(22) => "F22",
        Key::Function(23) => "F23",
        Key::Function(24) => "F24",
        Key::Function(25) => "F25",
        Key::Function(26) => "F26",
        Key::Function(27) => "F27",
        Key::Function(28) => "F28",
        Key::Function(29) => "F29",
        Key::Function(30) => "F30",
        Key::Function(31) => "F31",
        Key::Function(32) => "F32",
        Key::Function(33) => "F33",
        Key::Function(34) => "F34",
        Key::Function(35) => "F35",
        Key::Escape => "Esc",
        Key::Tab => "Tab",
        Key::Backspace => "Backspace",
        Key::Return => "Return",
        Key::Enter => "Enter",
        Key::Insert => "Insert",
        Key::Delete => "Delete",
        Key::Pause => "Pause",
        Key::Print => "Print",
        Key::Home => "Home",
        Key::End => "End",
        Key::Left => "Left",
        Key::Up => "Up",
        Key::Right => "Right",
        Key::Down => "Down",
        Key::PageUp => "PageUp",
        Key::PageDown => "PageDown",
        Key::Space => "Space",
        Key::Apostrophe => "Apostrophe",
        Key::Comma => "Comma",
        Key::Minus => "Minus",
        Key::Period => "Period",
        Key::Slash => "Slash",
        Key::Semicolon => "Semicolon",
        Key::Equal => "Equal",
        Key::BracketLeft => "BracketLeft",
        Key::Backslash => "Backslash",
        Key::BracketRight => "BracketRight",
        Key::Grave => "Grave",
        Key::AudioLowerVolume => "VolumeDown",
        Key::AudioMute => "Mute",
        Key::AudioRaiseVolume => "VolumeUp",
        Key::AudioPlay => "Play",
        Key::AudioStop => "Stop",
        Key::AudioPrev => "Prev",
        Key::AudioNext => "Next",
        Key::AudioPause => "PauseMedia",
        Key::BrightnessUp => "BrightnessUp",
        Key::BrightnessDown => "BrightnessDown",
        Key::Character(_) => "Key",
        Key::Function(_) => "F",
    }
}

pub(crate) fn validate_shortcuts(shortcuts: &[(&str, &str)]) -> Result<(), String> {
    let mut parsed = Vec::new();
    for &(field, shortcut) in shortcuts {
        let shortcut = shortcut.trim();
        if shortcut.is_empty() {
            continue;
        }
        let binding = parse_shortcut(shortcut).map_err(|error| format!("{field}: {error}"))?;
        if let Some((other, _)) = parsed.iter().find(|(_, existing)| *existing == binding) {
            return Err(format!("{field}: shortcut is already used by {other}"));
        }
        parsed.push((field, binding));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{config_key_name, format_shortcut, shortcut_from_key, validate_shortcuts};
    use eframe::egui;

    #[test]
    fn rejects_duplicate_shortcuts() {
        assert_eq!(
            validate_shortcuts(&[("copy", "Alt+1"), ("ocr", "Alt+1")]),
            Err("ocr: shortcut is already used by copy".to_owned())
        );
    }

    #[test]
    fn accepts_distinct_shortcuts() {
        assert_eq!(
            validate_shortcuts(&[("copy", "Alt+1"), ("ocr", "Alt+2"), ("one line", "")]),
            Ok(())
        );
    }

    #[test]
    fn maps_shortcut_keys() {
        assert_eq!(config_key_name(egui::Key::Num1).as_deref(), Some("1"));
        let modifiers = egui::Modifiers {
            alt: true,
            ..Default::default()
        };
        assert_eq!(
            shortcut_from_key(egui::Key::Num1, modifiers).as_deref(),
            Some("Alt+1")
        );
    }

    #[test]
    fn formats_shortcuts_per_platform() {
        let expected = if cfg!(target_os = "macos") {
            "Opt+1"
        } else {
            "Alt+1"
        };
        assert_eq!(format_shortcut("Alt+1"), expected);
    }
}
