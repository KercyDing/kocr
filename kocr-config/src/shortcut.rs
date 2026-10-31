//! Shortcut syntax used by the configuration file.
//!
//! Codes follow KDE's Qt key encoding because the Linux daemon feeds them to
//! KGlobalAccel. The syntax itself is platform neutral; other backends can map
//! a parsed shortcut to their own representation.

use thiserror::Error;

const QT_SHIFT: i32 = 0x0200_0000;
const QT_CONTROL: i32 = 0x0400_0000;
const QT_ALT: i32 = 0x0800_0000;
const QT_META: i32 = 0x1000_0000;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ShortcutError {
    #[error("invalid shortcut: {0}")]
    Invalid(String),
    #[error("unsupported shortcut key: {0}")]
    UnsupportedKey(String),
}

pub fn parse_shortcut(shortcut: &str) -> Result<i32, ShortcutError> {
    let mut parts = shortcut.split('+').peekable();
    let mut modifiers = 0;
    let mut key = None;
    while let Some(part) = parts.next() {
        let part = part.trim();
        if part.is_empty() {
            return Err(ShortcutError::Invalid(shortcut.to_owned()));
        }
        let modifier = match part {
            "Mod" | "Super" | "Meta" => Some(QT_META),
            "Ctrl" | "Control" => Some(QT_CONTROL),
            "Alt" => Some(QT_ALT),
            "Shift" => Some(QT_SHIFT),
            _ => None,
        };
        if let Some(modifier) = modifier {
            if key.is_some() || modifiers & modifier != 0 {
                return Err(ShortcutError::Invalid(shortcut.to_owned()));
            }
            modifiers |= modifier;
            continue;
        }
        if parts.peek().is_some() || key.replace(parse_key(part)?).is_some() {
            return Err(ShortcutError::Invalid(shortcut.to_owned()));
        }
    }
    key.map(|key| modifiers | key)
        .ok_or_else(|| ShortcutError::Invalid(shortcut.to_owned()))
}

fn parse_key(name: &str) -> Result<i32, ShortcutError> {
    if name.len() == 1 {
        let character = name.chars().next().expect("one-byte key has one character");
        if character.is_ascii_alphanumeric() {
            return Ok(character.to_ascii_uppercase() as i32);
        }
    }
    if let Some(number) = name
        .strip_prefix('F')
        .and_then(|value| value.parse::<i32>().ok())
        && (1..=35).contains(&number)
    {
        return Ok(0x0100_0030 + number - 1);
    }
    let key = match name {
        "Escape" => 0x0100_0000,
        "Tab" => 0x0100_0001,
        "BackSpace" | "Backspace" => 0x0100_0003,
        "Return" => 0x0100_0004,
        "Enter" => 0x0100_0005,
        "Insert" => 0x0100_0006,
        "Delete" => 0x0100_0007,
        "Pause" => 0x0100_0008,
        "Print" => 0x0100_0009,
        "Home" => 0x0100_0010,
        "End" => 0x0100_0011,
        "Left" => 0x0100_0012,
        "Up" => 0x0100_0013,
        "Right" => 0x0100_0014,
        "Down" => 0x0100_0015,
        "Page_Up" | "PageUp" => 0x0100_0016,
        "Page_Down" | "PageDown" => 0x0100_0017,
        "Space" => 0x20,
        "Apostrophe" => '\'' as i32,
        "Comma" => ',' as i32,
        "Minus" => '-' as i32,
        "Period" => '.' as i32,
        "Slash" => '/' as i32,
        "Semicolon" => ';' as i32,
        "Equal" => '=' as i32,
        "BracketLeft" => '[' as i32,
        "Backslash" => '\\' as i32,
        "BracketRight" => ']' as i32,
        "Grave" => '`' as i32,
        "XF86AudioLowerVolume" => 0x0100_0070,
        "XF86AudioMute" => 0x0100_0071,
        "XF86AudioRaiseVolume" => 0x0100_0072,
        "XF86AudioPlay" => 0x0100_0080,
        "XF86AudioStop" => 0x0100_0081,
        "XF86AudioPrev" => 0x0100_0082,
        "XF86AudioNext" => 0x0100_0083,
        "XF86AudioPause" => 0x0100_0085,
        "XF86MonBrightnessUp" => 0x0100_00b2,
        "XF86MonBrightnessDown" => 0x0100_00b3,
        _ => return Err(ShortcutError::UnsupportedKey(name.to_owned())),
    };
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::{QT_ALT, QT_META, QT_SHIFT, ShortcutError, parse_shortcut};

    #[test]
    fn parses_shortcuts() {
        assert_eq!(parse_shortcut("Alt+1").unwrap(), QT_ALT | '1' as i32);
        assert_eq!(
            parse_shortcut("Mod+Shift+Slash").unwrap(),
            QT_META | QT_SHIFT | '/' as i32
        );
    }

    #[test]
    fn rejects_duplicate_modifier() {
        assert!(matches!(
            parse_shortcut("Alt+Alt+1"),
            Err(ShortcutError::Invalid(_))
        ));
    }

    #[test]
    fn rejects_missing_key() {
        assert!(matches!(
            parse_shortcut("Ctrl"),
            Err(ShortcutError::Invalid(_))
        ));
    }

    #[test]
    fn rejects_unknown_key() {
        assert_eq!(
            parse_shortcut("Alt+NoSuchKey"),
            Err(ShortcutError::UnsupportedKey("NoSuchKey".to_owned()))
        );
    }
}
