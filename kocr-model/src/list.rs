use std::path::PathBuf;

use super::{ModelError, load_index, model_path, selected_profile, sync_config};

#[derive(Debug)]
pub struct Entry {
    pub name: String,
    pub id: u32,
    pub path: PathBuf,
    pub installed: bool,
    pub active: bool,
}

pub fn run() -> Result<Vec<Entry>, ModelError> {
    sync_config()?;
    let index = load_index()?;
    let active = selected_profile().ok();
    let mut profiles: Vec<_> = index.profiles.iter().collect();
    profiles.sort_by_key(|(_, profile)| profile.id);
    profiles
        .into_iter()
        .map(|(name, profile)| {
            let path = model_path(name)?;
            Ok(Entry {
                name: name.clone(),
                id: profile.id,
                installed: path.join("manifest.toml").is_file(),
                path,
                active: active.as_deref() == Some(name.as_str()),
            })
        })
        .collect()
}
