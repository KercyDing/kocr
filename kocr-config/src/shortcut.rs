//! Shortcut syntax used by the configuration file.
//!
//! Parsing produces a platform-neutral [`Shortcut`]. Backends map it to their
//! native representation, so the syntax does not depend on any toolkit.

use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ShortcutError {
    #[error("invalid shortcut: {0}")]
    Invalid(String),
    #[error("unsupported shortcut key: {0}")]
    UnsupportedKey(String),
}

/// A parsed keyboard shortcut.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Shortcut {
    pub modifiers: Modifiers,
    pub key: Key,
}

/// Modifier keys supported by the configuration syntax.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct Modifiers(u8);

impl Modifiers {
    pub const SUPER: Self = Self(1 << 0);
    pub const CONTROL: Self = Self(1 << 1);
    pub const ALT: Self = Self(1 << 2);
    pub const SHIFT: Self = Self(1 << 3);

    pub const fn empty() -> Self {
        Self(0)
    }

    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    fn insert(&mut self, modifier: Modifier) -> bool {
        let bit = modifier.bits();
        let duplicate = self.contains(bit);
        self.0 |= bit.0;
        !duplicate
    }
}

#[derive(Debug, Clone, Copy)]
enum Modifier {
    Super,
    Control,
    Alt,
    Shift,
}

impl Modifier {
    fn bits(self) -> Modifiers {
        match self {
            Self::Super => Modifiers::SUPER,
            Self::Control => Modifiers::CONTROL,
            Self::Alt => Modifiers::ALT,
            Self::Shift => Modifiers::SHIFT,
        }
    }
}

/// A key accepted by the configuration syntax.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Key {
    Character(char),
    Function(u8),
    Escape,
    Tab,
    Backspace,
    Return,
    Enter,
    Insert,
    Delete,
    Pause,
    Print,
    Home,
    End,
    Left,
    Up,
    Right,
    Down,
    PageUp,
    PageDown,
    Space,
    Apostrophe,
    Comma,
    Minus,
    Period,
    Slash,
    Semicolon,
    Equal,
    BracketLeft,
    Backslash,
    BracketRight,
    Grave,
    AudioLowerVolume,
    AudioMute,
    AudioRaiseVolume,
    AudioPlay,
    AudioStop,
    AudioPrev,
    AudioNext,
    AudioPause,
    BrightnessUp,
    BrightnessDown,
}

pub fn parse_shortcut(shortcut: &str) -> Result<Shortcut, ShortcutError> {
    let mut parts = shortcut.split('+').peekable();
    let mut modifiers = Modifiers::empty();
    let mut key = None;
    while let Some(part) = parts.next() {
        let part = part.trim();
        if part.is_empty() {
            return Err(ShortcutError::Invalid(shortcut.to_owned()));
        }
        let modifier = match part {
            "Mod" | "Super" | "Meta" => Some(Modifier::Super),
            "Ctrl" | "Control" => Some(Modifier::Control),
            "Alt" => Some(Modifier::Alt),
            "Shift" => Some(Modifier::Shift),
            _ => None,
        };
        if let Some(modifier) = modifier {
            if key.is_some() || !modifiers.insert(modifier) {
                return Err(ShortcutError::Invalid(shortcut.to_owned()));
            }
            continue;
        }
        if parts.peek().is_some() || key.replace(parse_key(part)?).is_some() {
            return Err(ShortcutError::Invalid(shortcut.to_owned()));
        }
    }
    key.map(|key| Shortcut { modifiers, key })
        .ok_or_else(|| ShortcutError::Invalid(shortcut.to_owned()))
}

fn parse_key(name: &str) -> Result<Key, ShortcutError> {
    if name.len() == 1 {
        let character = name.chars().next().expect("one-byte key has one character");
        if character.is_ascii_alphanumeric() {
            return Ok(Key::Character(character.to_ascii_uppercase()));
        }
    }
    if let Some(number) = name
        .strip_prefix('F')
        .and_then(|value| value.parse::<u8>().ok())
        && (1..=35).contains(&number)
    {
        return Ok(Key::Function(number));
    }
    let key = match name {
        "Escape" => Key::Escape,
        "Tab" => Key::Tab,
        "BackSpace" | "Backspace" => Key::Backspace,
        "Return" => Key::Return,
        "Enter" => Key::Enter,
        "Insert" => Key::Insert,
        "Delete" => Key::Delete,
        "Pause" => Key::Pause,
        "Print" => Key::Print,
        "Home" => Key::Home,
        "End" => Key::End,
        "Left" => Key::Left,
        "Up" => Key::Up,
        "Right" => Key::Right,
        "Down" => Key::Down,
        "Page_Up" | "PageUp" => Key::PageUp,
        "Page_Down" | "PageDown" => Key::PageDown,
        "Space" => Key::Space,
        "Apostrophe" => Key::Apostrophe,
        "Comma" => Key::Comma,
        "Minus" => Key::Minus,
        "Period" => Key::Period,
        "Slash" => Key::Slash,
        "Semicolon" => Key::Semicolon,
        "Equal" => Key::Equal,
        "BracketLeft" => Key::BracketLeft,
        "Backslash" => Key::Backslash,
        "BracketRight" => Key::BracketRight,
        "Grave" => Key::Grave,
        "XF86AudioLowerVolume" => Key::AudioLowerVolume,
        "XF86AudioMute" => Key::AudioMute,
        "XF86AudioRaiseVolume" => Key::AudioRaiseVolume,
        "XF86AudioPlay" => Key::AudioPlay,
        "XF86AudioStop" => Key::AudioStop,
        "XF86AudioPrev" => Key::AudioPrev,
        "XF86AudioNext" => Key::AudioNext,
        "XF86AudioPause" => Key::AudioPause,
        "XF86MonBrightnessUp" => Key::BrightnessUp,
        "XF86MonBrightnessDown" => Key::BrightnessDown,
        _ => return Err(ShortcutError::UnsupportedKey(name.to_owned())),
    };
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::{Key, Modifiers, Shortcut, ShortcutError, parse_shortcut};

    #[test]
    fn parses_shortcuts() {
        assert_eq!(
            parse_shortcut("Alt+1").unwrap(),
            Shortcut {
                modifiers: Modifiers::ALT,
                key: Key::Character('1'),
            }
        );
        let shortcut = parse_shortcut("Mod+Shift+Slash").unwrap();
        assert!(shortcut.modifiers.contains(Modifiers::SUPER));
        assert!(shortcut.modifiers.contains(Modifiers::SHIFT));
        assert_eq!(shortcut.key, Key::Slash);
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
