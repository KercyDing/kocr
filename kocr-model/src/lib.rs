mod catalog;
pub mod hash;
pub mod install;
pub mod list;
pub mod uninstall;
pub mod r#use;

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use kocr_config::{Config as ModelConfig, InstalledModel, ModelsConfig, ShortcutConfig};
use thiserror::Error;

use crate::catalog::{ModelIndex, ModelProfile, profiles};

pub use install::{InstallResult, Progress, run as install};
pub use list::{Entry as ModelEntry, run as list};
pub use uninstall::run as uninstall;
pub use r#use::run as use_model;

const MODEL_DIR: &str = "kocr/models";

impl From<kocr_config::ConfigError> for ModelError {
    fn from(error: kocr_config::ConfigError) -> Self {
        Self::Operation(error.to_string())
    }
}

#[derive(Debug, Error)]
pub enum ModelError {
    #[error("{0}")]
    Index(String),

    #[error("{0}")]
    Operation(String),
}

pub(crate) fn load_index() -> Result<ModelIndex, ModelError> {
    let index = ModelIndex {
        profiles: profiles(),
    };
    validate_index(&index)?;
    Ok(index)
}

pub fn selected_profile() -> Result<String, ModelError> {
    sync_config()?;
    let index = load_index()?;
    let configured = read_config()?;
    let config = ModelConfig::load()?;
    let installed = installed_profiles_from(&index, &config);
    if let Some(configured) = configured {
        if installed.iter().any(|name| name == &configured) {
            return Ok(configured);
        }
        if let Some(profile) = index.profiles.get(&configured)
            && let Some(name) = installed.iter().find(|name| {
                index
                    .profiles
                    .get(*name)
                    .is_some_and(|candidate| candidate.id > profile.id)
            })
        {
            return Ok(name.clone());
        }
    }
    installed
        .into_iter()
        .next()
        .ok_or_else(|| ModelError::Operation("no model profile is installed".to_owned()))
}

pub fn shortcuts() -> Result<ShortcutConfig, ModelError> {
    sync_config()?;
    let mut shortcuts = ModelConfig::load()?.shortcut;
    shortcuts.copy = non_empty(shortcuts.copy);
    shortcuts.ocr = non_empty(shortcuts.ocr);
    shortcuts.oneline = non_empty(shortcuts.oneline);
    Ok(shortcuts)
}

pub fn model_path(name: &str) -> Result<PathBuf, ModelError> {
    let config = ModelConfig::load()?;
    Ok(configured_path(&config, name).unwrap_or_else(|| default_model_path(name)))
}

pub(crate) fn resolve_profile<'a>(
    index: &'a ModelIndex,
    selector: &str,
) -> Result<(&'a str, &'a ModelProfile), ModelError> {
    if let Ok(id) = selector.parse::<u32>() {
        return index
            .profiles
            .iter()
            .find(|(_, profile)| profile.id == id)
            .map(|(name, profile)| (name.as_str(), profile))
            .ok_or_else(|| ModelError::Index(format!("unknown model ID: {id}")));
    }
    index
        .profiles
        .get_key_value(selector)
        .map(|(name, profile)| (name.as_str(), profile))
        .ok_or_else(|| ModelError::Index(format!("unknown model profile: {selector}")))
}

pub(crate) fn installed_profiles(index: &ModelIndex) -> Result<Vec<String>, ModelError> {
    let config = ModelConfig::load()?;
    Ok(installed_profiles_from(index, &config))
}

pub fn installed_model_names() -> Result<Vec<String>, ModelError> {
    let index = load_index()?;
    installed_profiles(&index)
}

fn installed_profiles_from(index: &ModelIndex, config: &ModelConfig) -> Vec<String> {
    let mut profiles: Vec<_> = index
        .profiles
        .iter()
        .filter(|(name, _)| configured_path(config, name).is_some_and(|path| has_manifest(&path)))
        .map(|(name, _)| name.clone())
        .collect();
    profiles.sort_by_key(|name| index.profiles[name].id);
    profiles
}

pub fn load_config() -> Result<ModelConfig, ModelError> {
    Ok(ModelConfig::load()?)
}

pub fn read_config() -> Result<Option<String>, ModelError> {
    Ok(load_config()?.models.select)
}

pub fn sync_config() -> Result<(), ModelError> {
    let index = load_index()?;
    let path = kocr_config::config_path();
    let had_config = path.is_file();
    let mut config = ModelConfig::load()?;
    let mut installed = BTreeMap::new();
    for name in index.profiles.keys() {
        let configured = configured_path(&config, name).filter(|path| has_manifest(path));
        let path = configured.or_else(|| {
            let path = default_model_path(name);
            has_manifest(&path).then_some(path)
        });
        if let Some(path) = path {
            installed.insert(
                name.clone(),
                InstalledModel {
                    path: path.display().to_string(),
                },
            );
        }
    }
    let mut installed_names: Vec<_> = installed.keys().cloned().collect();
    installed_names.sort_by_key(|name| index.profiles[name].id);
    let select = config
        .models
        .select
        .as_ref()
        .filter(|name| installed_names.iter().any(|installed| installed == *name))
        .cloned()
        .or_else(|| installed_names.first().cloned());
    let updated_models = ModelsConfig { select, installed };
    let changed = config.models != updated_models;
    config.models = updated_models;
    if changed && (had_config || !config.models.installed.is_empty()) {
        save_config(&config)?;
    }
    Ok(())
}

pub(crate) fn write_config(name: &str) -> Result<(), ModelError> {
    let mut config = ModelConfig::load()?;
    config.models.select = Some(name.to_owned());
    save_config(&config)
}

pub(crate) fn record_install(name: &str, path: &Path) -> Result<(), ModelError> {
    let mut config = ModelConfig::load()?;
    config.models.select = Some(name.to_owned());
    config.models.installed.insert(
        name.to_owned(),
        InstalledModel {
            path: path.display().to_string(),
        },
    );
    save_config(&config)
}

pub(crate) fn remove_config(name: &str) -> Result<(), ModelError> {
    let path = kocr_config::config_path();
    if !path.is_file() {
        return Ok(());
    }
    let mut config = ModelConfig::load()?;
    config.models.installed.remove(name);
    if config.models.select.as_deref() == Some(name) {
        config.models.select = None;
    }
    if config.is_empty() {
        fs::remove_file(path).map_err(|error| {
            ModelError::Operation(format!("could not clear model configuration: {error}"))
        })?;
        return Ok(());
    }
    save_config(&config)
}

fn save_config(config: &ModelConfig) -> Result<(), ModelError> {
    Ok(config.save()?)
}

pub fn config_path() -> PathBuf {
    kocr_config::config_path()
}

pub(crate) fn validate_index(index: &ModelIndex) -> Result<(), ModelError> {
    let mut ids = BTreeSet::new();
    for (name, profile) in &index.profiles {
        if profile.id == 0 {
            return Err(ModelError::Index(format!(
                "model ID must be positive: {name}"
            )));
        }
        if !ids.insert(profile.id) {
            return Err(ModelError::Index(format!(
                "duplicate model ID: {}",
                profile.id
            )));
        }
    }
    Ok(())
}

fn model_root() -> PathBuf {
    kocr_platform::data_home().join(MODEL_DIR)
}

pub(crate) fn default_model_path(name: &str) -> PathBuf {
    model_root().join(name)
}

fn configured_path(config: &ModelConfig, name: &str) -> Option<PathBuf> {
    config
        .models
        .installed
        .get(name)
        .map(|model| PathBuf::from(&model.path))
}

fn has_manifest(path: &Path) -> bool {
    kocr_config::is_model_installed(path)
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|value| !value.trim().is_empty())
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::fs;

    use super::{installed_profiles_from, load_index, resolve_profile};
    use kocr_config::{Config as ModelConfig, InstalledModel, ModelsConfig};

    #[test]
    fn resolves_id() {
        let index = load_index().unwrap();
        let (name, _) = resolve_profile(&index, "1").unwrap();
        assert_eq!(name, "ppocrv6-small-int8-r1");
    }

    #[test]
    fn resolves_name() {
        let index = load_index().unwrap();
        let (name, _) = resolve_profile(&index, "ppocrv6-small-int8-r1").unwrap();
        assert_eq!(name, "ppocrv6-small-int8-r1");
    }

    #[test]
    fn finds_custom_path() {
        let index = load_index().unwrap();
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("custom-small");
        fs::create_dir(&path).unwrap();
        fs::write(path.join("manifest.toml"), "").unwrap();
        let config = ModelConfig {
            models: ModelsConfig {
                select: Some("ppocrv6-small-int8-r1".to_owned()),
                installed: BTreeMap::from([(
                    "ppocrv6-small-int8-r1".to_owned(),
                    InstalledModel {
                        path: path.display().to_string(),
                    },
                )]),
            },
            ..ModelConfig::default()
        };

        assert_eq!(
            installed_profiles_from(&index, &config),
            vec!["ppocrv6-small-int8-r1"]
        );
    }
}
