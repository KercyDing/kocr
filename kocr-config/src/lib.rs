//! Configuration file shared by the kocr daemon and the settings UI.

use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub mod shortcut;

pub use shortcut::{ShortcutError, parse_shortcut};

const CONFIG_FILE: &str = "kocr/config.toml";
const LEGACY_CONFIG_FILE: &str = "kdeocr/config.toml";
const DEFAULT_COPY_SHORTCUT: &str = "Alt+1";
const DEFAULT_OCR_SHORTCUT: &str = "Alt+2";
const DEFAULT_ONELINE_SHORTCUT: &str = "Alt+3";

/// Header written above the serialized configuration.
pub const CONFIG_COMMENTS: &str = "# Supported modifiers: Mod, Ctrl, Alt, Shift.\n# Key examples: A-Z, 0-9, F1-F35, Escape, Space, Slash.\n# Set a shortcut to an empty string to disable it.\n\n";

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("{0}")]
    Operation(String),
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct ShortcutConfig {
    #[serde(
        default = "default_copy_shortcut",
        skip_serializing_if = "Option::is_none"
    )]
    pub copy: Option<String>,
    #[serde(
        default = "default_ocr_shortcut",
        skip_serializing_if = "Option::is_none"
    )]
    pub ocr: Option<String>,
    #[serde(
        default = "default_oneline_shortcut",
        skip_serializing_if = "Option::is_none"
    )]
    pub oneline: Option<String>,
}

fn default_copy_shortcut() -> Option<String> {
    Some(DEFAULT_COPY_SHORTCUT.to_owned())
}

fn default_ocr_shortcut() -> Option<String> {
    Some(DEFAULT_OCR_SHORTCUT.to_owned())
}

fn default_oneline_shortcut() -> Option<String> {
    Some(DEFAULT_ONELINE_SHORTCUT.to_owned())
}

impl Default for ShortcutConfig {
    fn default() -> Self {
        Self {
            copy: default_copy_shortcut(),
            ocr: default_ocr_shortcut(),
            oneline: default_oneline_shortcut(),
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
pub struct Config {
    #[serde(default)]
    pub shortcut: ShortcutConfig,
    #[serde(default)]
    pub models: ModelsConfig,
    #[serde(flatten)]
    pub extra: BTreeMap<String, toml::Value>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
pub struct ModelsConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub select: Option<String>,
    #[serde(flatten)]
    pub installed: BTreeMap<String, InstalledModel>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct InstalledModel {
    pub path: String,
}

impl Config {
    pub fn load() -> Result<Self, ConfigError> {
        Self::load_from(&config_path())
    }

    pub fn load_from(path: &Path) -> Result<Self, ConfigError> {
        if !path.is_file() {
            return Ok(Self::default());
        }
        let content = fs::read_to_string(path)
            .map_err(|error| ConfigError::Operation(format!("could not read config: {error}")))?;
        toml::from_str(&content)
            .map_err(|error| ConfigError::Operation(format!("could not parse config: {error}")))
    }

    pub fn save(&self) -> Result<(), ConfigError> {
        self.save_to(&config_path())
    }

    /// Write through a temporary file so readers never observe a partial file.
    pub fn save_to(&self, path: &Path) -> Result<(), ConfigError> {
        let parent = path
            .parent()
            .ok_or_else(|| ConfigError::Operation("invalid config path".to_owned()))?;
        fs::create_dir_all(parent).map_err(|error| {
            ConfigError::Operation(format!("could not create config directory: {error}"))
        })?;
        let temporary = tempfile::NamedTempFile::new_in(parent).map_err(|error| {
            ConfigError::Operation(format!("could not create config file: {error}"))
        })?;
        let content = toml::to_string_pretty(self).map_err(|error| {
            ConfigError::Operation(format!("could not serialize config: {error}"))
        })?;
        fs::write(temporary.path(), format!("{CONFIG_COMMENTS}{content}"))
            .map_err(|error| ConfigError::Operation(format!("could not write config: {error}")))?;
        temporary.persist(path).map_err(|error| {
            ConfigError::Operation(format!("could not install config: {error}"))
        })?;
        Ok(())
    }

    pub fn is_empty(&self) -> bool {
        self.shortcut == ShortcutConfig::default()
            && self.models == ModelsConfig::default()
            && self.extra.is_empty()
    }
}

pub fn config_path() -> PathBuf {
    let base = config_home();
    let path = base.join(CONFIG_FILE);
    migrate(&base.join(LEGACY_CONFIG_FILE), &path);
    path
}

fn config_home() -> PathBuf {
    env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home_dir().join(".config"))
}

fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn migrate(legacy: &Path, current: &Path) {
    if current.exists() || !legacy.is_file() {
        return;
    }
    let Some(parent) = current.parent() else {
        return;
    };
    if fs::create_dir_all(parent).is_err() {
        return;
    }
    let _ = fs::rename(legacy, current);
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{Config, InstalledModel, ModelsConfig, ShortcutConfig};
    use crate::CONFIG_COMMENTS;

    fn sample() -> Config {
        Config {
            shortcut: ShortcutConfig {
                copy: Some("Alt+1".to_owned()),
                ocr: Some("Alt+2".to_owned()),
                oneline: Some("Alt+3".to_owned()),
            },
            models: ModelsConfig {
                select: Some("ppocrv6-small-r1".to_owned()),
                installed: BTreeMap::from([(
                    "ppocrv6-small-r1".to_owned(),
                    InstalledModel {
                        path: "/models/ppocrv6-small-r1".to_owned(),
                    },
                )]),
            },
            extra: BTreeMap::new(),
        }
    }

    #[test]
    fn serializes_config() {
        let content = toml::to_string_pretty(&sample()).unwrap();

        assert_eq!(
            content,
            "[shortcut]\ncopy = \"Alt+1\"\nocr = \"Alt+2\"\noneline = \"Alt+3\"\n\n[models]\nselect = \"ppocrv6-small-r1\"\n\n[models.ppocrv6-small-r1]\npath = \"/models/ppocrv6-small-r1\"\n"
        );
    }

    #[test]
    fn preserves_extra_config() {
        let config: Config =
            toml::from_str("[models]\nselect = \"ppocrv6-small-r1\"\n\n[ocr]\nthreshold = 0.5\n")
                .unwrap();
        let content = toml::to_string_pretty(&config).unwrap();

        assert!(content.contains("ocr"));
        assert!(content.contains("threshold = 0.5"));
    }

    #[test]
    fn defaults_shortcuts() {
        assert_eq!(
            Config::default().shortcut,
            ShortcutConfig {
                copy: Some("Alt+1".to_owned()),
                ocr: Some("Alt+2".to_owned()),
                oneline: Some("Alt+3".to_owned()),
            }
        );
    }

    #[test]
    fn fills_missing_shortcuts() {
        let config: Config =
            toml::from_str("[shortcut]\ncopy = \"Alt+4\"\nocr = \"Alt+5\"\n").unwrap();

        assert_eq!(config.shortcut.copy.as_deref(), Some("Alt+4"));
        assert_eq!(config.shortcut.ocr.as_deref(), Some("Alt+5"));
        assert_eq!(config.shortcut.oneline.as_deref(), Some("Alt+3"));
    }

    #[test]
    fn round_trips_through_file() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let config = sample();

        config.save_to(&path).unwrap();

        let raw = std::fs::read_to_string(&path).unwrap();
        assert!(raw.starts_with(CONFIG_COMMENTS));
        assert_eq!(Config::load_from(&path).unwrap(), config);
    }

    #[test]
    fn replaces_existing_file_atomically() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        std::fs::write(&path, "garbage = [").unwrap();

        let mut config = Config::default();
        config.shortcut.copy = Some("Alt+9".to_owned());
        config.save_to(&path).unwrap();

        assert_eq!(
            Config::load_from(&path).unwrap().shortcut.copy.as_deref(),
            Some("Alt+9")
        );
    }

    #[test]
    fn missing_file_uses_defaults() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("missing.toml");

        assert_eq!(Config::load_from(&path).unwrap(), Config::default());
    }

    #[test]
    fn empty_shortcut_is_kept() {
        let config: Config = toml::from_str("[shortcut]\ncopy = \"\"\n").unwrap();

        assert_eq!(config.shortcut.copy.as_deref(), Some(""));
        assert_eq!(config.shortcut.ocr.as_deref(), Some("Alt+2"));
    }
}
